# frozen_string_literal: true

module DiscourseCommunityMap
  class CommunityMapController < ::ApplicationController
    requires_plugin DiscourseCommunityMap::PLUGIN_NAME

    skip_before_action :check_xhr, only: [:show]
    skip_before_action :redirect_to_login_if_required, only: [:show, :members]
    skip_before_action :verify_authenticity_token, only: [:members]

    GEOCODE_CACHE_KEY = "community_map_geocode_cache"

    # GET /community-map — Standalone HTML page with Leaflet map
    def show
      response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' https://*.basemaps.cartocdn.com https://*.tile.openstreetmap.org https://campus.outoftheb-ox.de data:; connect-src 'self'; frame-ancestors 'self' https://campus.outoftheb-ox.de https://www.outoftheb-ox.de"
      render html: map_page_html.html_safe, layout: false
    end

    # GET /community-map/members.json — JSON array of members with coordinates
    def members
      response.headers["Access-Control-Allow-Origin"] = "*"
      response.headers["Cache-Control"] = "public, max-age=300"

      cache_key = "community_map_members_v1"
      cache_duration = (SiteSetting.community_map_cache_duration_minutes || 60).minutes

      result = Discourse.cache.fetch(cache_key, expires_in: cache_duration) do
        build_members_json
      end

      render json: result, root: false
    end

    private

    def build_members_json
      location_field = find_user_field(SiteSetting.community_map_location_field)
      return [] unless location_field

      position_field = find_user_field(SiteSetting.community_map_position_field)
      about_field = find_user_field(SiteSetting.community_map_about_field)

      users = User.real.activated.not_suspended
        .where("trust_level >= ?", SiteSetting.community_map_min_trust_level)

      # Filter by groups if configured
      allowed_groups = SiteSetting.community_map_allowed_groups
      if allowed_groups.present?
        group_ids = allowed_groups.split("|").map(&:to_i)
        user_ids = GroupUser.where(group_id: group_ids).pluck(:user_id).uniq
        users = users.where(id: user_ids)
      end

      # Load user custom fields
      user_ids = users.pluck(:id)
      field_ids = [location_field.id, position_field&.id, about_field&.id].compact
      custom_fields = UserCustomField
        .where(user_id: user_ids, name: field_ids.map { |id| "user_field_#{id}" })
        .pluck(:user_id, :name, :value)
        .group_by(&:first)

      geocode_cache = load_geocode_cache

      members = []

      users.find_each do |user|
        fields = custom_fields[user.id] || []
        city = field_value(fields, location_field.id)
        next if city.blank?

        coords = geocode_city(city, geocode_cache)
        next unless coords

        position = position_field ? field_value(fields, position_field.id) : nil
        about = about_field ? field_value(fields, about_field.id) : user.user_profile&.bio_excerpt

        initials = [user.name&.split(" ")&.first&.[](0), user.name&.split(" ")&.last&.[](0)]
          .compact.join("").upcase
        initials = user.username[0..1].upcase if initials.blank?

        members << {
          name: user.name.presence || user.username,
          city: city,
          lat: coords[:lat],
          lng: coords[:lng],
          position: position || "",
          about: (about || "")[0..200],
          initials: initials,
          username: user.username,
          avatar_url: user.avatar_template_url.gsub("{size}", "120")
        }
      end

      save_geocode_cache(geocode_cache)
      members
    end

    def find_user_field(name)
      return nil if name.blank?
      UserField.find_by("name ILIKE ?", name.strip)
    end

    def field_value(fields, field_id)
      entry = fields.find { |_, name, _| name == "user_field_#{field_id}" }
      entry&.last&.presence
    end

    def load_geocode_cache
      raw = PluginStore.get(DiscourseCommunityMap::PLUGIN_NAME, GEOCODE_CACHE_KEY)
      raw.is_a?(Hash) ? raw : {}
    end

    def save_geocode_cache(cache)
      PluginStore.set(DiscourseCommunityMap::PLUGIN_NAME, GEOCODE_CACHE_KEY, cache)
    end

    def geocode_city(city, cache)
      cache_key = city.strip.downcase
      return cache[cache_key] if cache[cache_key]

      begin
        uri = URI("https://nominatim.openstreetmap.org/search")
        uri.query = URI.encode_www_form(
          format: "json",
          q: city,
          limit: 1,
          countrycodes: "de,at,ch"
        )

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "DiscourseCommunityMap/1.0"

        response = http.request(request)
        data = JSON.parse(response.body)

        if data.is_a?(Array) && data.first
          coords = { lat: data.first["lat"].to_f, lng: data.first["lon"].to_f }
          cache[cache_key] = coords
          sleep(1.1) # Nominatim rate limit
          return coords
        end
      rescue => e
        Rails.logger.warn("CommunityMap geocode error for '#{city}': #{e.message}")
      end

      nil
    end

    def leaflet_css
      @leaflet_css ||= File.read(File.join(File.dirname(__FILE__), "../../assets/vendor/leaflet.min.css"))
    end

    def leaflet_js
      @leaflet_js ||= File.read(File.join(File.dirname(__FILE__), "../../assets/vendor/leaflet.min.js"))
    end

    def map_page_html
      base_url = Discourse.base_url
      site_title = SiteSetting.title

      <<~HTML
        <!DOCTYPE html>
        <html lang="de">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <title>Community Map — #{ERB::Util.html_escape(site_title)}</title>
          <style>#{leaflet_css}</style>
          <style>
            :root {
              --cm-bg: #1a1d23;
              --cm-surface: #22262e;
              --cm-surface-hover: #2a2f38;
              --cm-border: #333842;
              --cm-text: #e8ecf1;
              --cm-text-secondary: #8b95a5;
              --cm-accent: #6c8cff;
              --cm-accent-soft: rgba(108,140,255,.12);
            }

            * { margin: 0; padding: 0; box-sizing: border-box; }

            html, body {
              height: 100%;
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
              background: var(--cm-bg);
              color: var(--cm-text);
              overflow: hidden;
            }

            .app { display: flex; height: 100%; position: relative; }

            /* === BACK LINK === */
            .back-link {
              position: absolute;
              top: 16px;
              left: 16px;
              z-index: 20;
              background: var(--cm-surface);
              border: 1px solid var(--cm-border);
              border-radius: 10px;
              padding: 8px 14px;
              color: var(--cm-text);
              text-decoration: none;
              font-size: 13px;
              font-weight: 500;
              display: flex;
              align-items: center;
              gap: 6px;
              transition: background .15s;
              box-shadow: 0 2px 12px rgba(0,0,0,.3);
            }
            .back-link:hover { background: var(--cm-surface-hover); }
            .back-link svg { width: 14px; height: 14px; }

            /* === SIDEBAR === */
            .sidebar {
              width: 340px;
              min-width: 340px;
              background: var(--cm-bg);
              border-right: 1px solid var(--cm-border);
              display: flex;
              flex-direction: column;
              overflow: hidden;
              z-index: 10;
            }

            .sidebar-header {
              padding: 20px;
              border-bottom: 1px solid var(--cm-border);
            }

            .brand {
              display: flex;
              align-items: center;
              gap: 12px;
              margin-bottom: 16px;
            }

            .brand-icon {
              width: 42px;
              height: 42px;
              background: var(--cm-accent);
              border-radius: 12px;
              display: flex;
              align-items: center;
              justify-content: center;
              font-size: 18px;
            }

            .brand h1 { font-size: 18px; font-weight: 700; line-height: 1.2; }
            .brand p { font-size: 12px; color: var(--cm-text-secondary); margin-top: 2px; }

            .search {
              position: relative;
              display: flex;
              align-items: center;
            }

            .search svg {
              position: absolute;
              left: 12px;
              width: 16px;
              height: 16px;
              color: var(--cm-text-secondary);
              pointer-events: none;
            }

            .search input {
              width: 100%;
              padding: 10px 14px 10px 38px;
              border: 1px solid var(--cm-border);
              border-radius: 10px;
              background: var(--cm-surface);
              color: var(--cm-text);
              font-size: 14px;
              outline: none;
              transition: border-color .15s;
            }

            .search input::placeholder { color: var(--cm-text-secondary); }
            .search input:focus { border-color: var(--cm-accent); }

            .count {
              padding: 10px 20px;
              font-size: 12px;
              color: var(--cm-text-secondary);
              border-bottom: 1px solid var(--cm-border);
              font-weight: 500;
            }

            .member-list {
              flex: 1;
              overflow-y: auto;
              scrollbar-width: thin;
              scrollbar-color: var(--cm-border) transparent;
            }

            .member-item {
              display: flex;
              align-items: center;
              gap: 12px;
              padding: 14px 20px;
              cursor: pointer;
              transition: background .12s;
              border-bottom: 1px solid rgba(51,56,66,.5);
            }

            .member-item:hover, .member-item.active {
              background: var(--cm-surface-hover);
            }

            .member-avatar {
              width: 40px;
              height: 40px;
              min-width: 40px;
              border-radius: 50%;
              background: var(--cm-accent-soft);
              color: var(--cm-accent);
              display: flex;
              align-items: center;
              justify-content: center;
              font-weight: 700;
              font-size: 13px;
              overflow: hidden;
            }

            .member-avatar img {
              width: 100%;
              height: 100%;
              object-fit: cover;
              border-radius: 50%;
            }

            .member-info { flex: 1; min-width: 0; }

            .member-name {
              font-size: 14px;
              font-weight: 600;
              white-space: nowrap;
              overflow: hidden;
              text-overflow: ellipsis;
            }

            .member-name a {
              color: inherit;
              text-decoration: none;
            }
            .member-name a:hover { color: var(--cm-accent); }

            .member-position {
              font-size: 12px;
              color: var(--cm-accent);
              margin-top: 1px;
            }

            .member-city {
              font-size: 12px;
              color: var(--cm-text-secondary);
              display: flex;
              align-items: center;
              gap: 4px;
              margin-top: 2px;
            }

            .member-city svg { width: 12px; height: 12px; flex-shrink: 0; }

            /* === MAP === */
            .map-container { flex: 1; position: relative; }
            #map { width: 100%; height: 100%; }

            .leaflet-popup-content-wrapper {
              background: var(--cm-surface) !important;
              color: var(--cm-text) !important;
              border-radius: 12px !important;
              box-shadow: 0 4px 24px rgba(0,0,0,.4) !important;
              border: 1px solid var(--cm-border) !important;
            }
            .leaflet-popup-tip { background: var(--cm-surface) !important; }

            /* === LOADING STATE === */
            .loading-overlay {
              position: absolute;
              inset: 0;
              background: var(--cm-bg);
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              z-index: 100;
              gap: 16px;
              transition: opacity .3s;
            }

            .loading-overlay.hidden { opacity: 0; pointer-events: none; }

            .spinner {
              width: 32px;
              height: 32px;
              border: 3px solid var(--cm-border);
              border-top-color: var(--cm-accent);
              border-radius: 50%;
              animation: spin .8s linear infinite;
            }

            @keyframes spin { to { transform: rotate(360deg); } }

            .loading-text {
              font-size: 14px;
              color: var(--cm-text-secondary);
            }

            /* === MOBILE === */
            .mobile-search {
              display: none;
              position: absolute;
              top: 12px;
              left: 12px;
              right: 12px;
              z-index: 20;
              background: var(--cm-surface);
              border: 1px solid var(--cm-border);
              border-radius: 12px;
              padding: 0 14px;
              align-items: center;
              gap: 8px;
              box-shadow: 0 4px 20px rgba(0,0,0,.4);
            }
            .mobile-search svg { width: 16px; height: 16px; color: var(--cm-text-secondary); flex-shrink: 0; }
            .mobile-search input {
              flex: 1;
              padding: 12px 0;
              border: none;
              background: transparent;
              color: var(--cm-text);
              font-size: 14px;
              outline: none;
            }
            .mobile-search input::placeholder { color: var(--cm-text-secondary); }

            @media (max-width: 600px) {
              .back-link { display: none; }
              .mobile-search { display: flex; }

              .sidebar {
                position: fixed;
                bottom: 0;
                left: 0;
                right: 0;
                width: 100%;
                min-width: 0;
                height: auto;
                max-height: 85vh;
                border-right: none;
                border-top: 1px solid var(--cm-border);
                border-radius: 16px 16px 0 0;
                transition: transform .3s ease;
                z-index: 30;
              }

              .sidebar.sheet-peek { transform: translateY(calc(100% - 60px)); }
              .sidebar.sheet-half { transform: translateY(50%); }
              .sidebar.sheet-full { transform: translateY(0); }

              .sheet-handle {
                display: flex;
                flex-direction: column;
                align-items: center;
                padding: 12px 20px 10px;
                cursor: grab;
                user-select: none;
                -webkit-user-select: none;
                border-bottom: 1px solid var(--cm-border);
              }
              .sheet-handle-bar {
                width: 36px;
                height: 4px;
                background: var(--cm-border);
                border-radius: 2px;
                margin-bottom: 8px;
              }
              .sheet-handle-text { font-size: 14px; font-weight: 600; }
              .sheet-handle-sub { font-size: 12px; color: var(--cm-text-secondary); margin-top: 2px; }

              .count { display: none; }
              .member-item { padding: 12px 16px; }
              .member-avatar { width: 36px; height: 36px; min-width: 36px; font-size: 12px; }
              .member-name { font-size: 14px; }
              .member-position { font-size: 12px; }

              .leaflet-control-zoom {
                margin-right: 12px !important;
                margin-top: 70px !important;
              }
            }
          </style>
        </head>
        <body>

        <div class="app">
          <!-- Loading Overlay -->
          <div class="loading-overlay" id="loading">
            <div class="spinner"></div>
            <div class="loading-text">Mitglieder werden geladen...</div>
          </div>

          <!-- Mobile: Floating Search -->
          <div class="mobile-search">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
            <input type="text" id="mobile-search" placeholder="Name oder Stadt suchen...">
          </div>

          <!-- Sidebar -->
          <aside class="sidebar sheet-peek" id="sidebar">
            <div class="sheet-handle" id="sheet-handle">
              <div class="sheet-handle-bar"></div>
              <div class="sheet-handle-text" id="sheet-title">Community</div>
              <div class="sheet-handle-sub">Nach oben wischen f&uuml;r Liste</div>
            </div>

            <div class="sidebar-header" id="sidebar-header">
              <div class="brand">
                <div class="brand-icon">&#x1F30D;</div>
                <div>
                  <h1>Community Map</h1>
                  <p>Finde Mitglieder in deiner N&auml;he</p>
                </div>
              </div>
              <div class="search">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
                <input type="text" id="desktop-search" placeholder="Name oder Stadt suchen...">
              </div>
            </div>
            <div class="count" id="count"></div>
            <div class="member-list" id="member-list"></div>
          </aside>

          <!-- Map -->
          <div class="map-container">
            <!-- Back to Discourse link -->
            <a class="back-link" href="#{ERB::Util.html_escape(base_url)}">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 18-6-6 6-6"/></svg>
              Zur&uuml;ck zum Forum
            </a>
            <div id="map"></div>
          </div>
        </div>

        <script>#{leaflet_js}</script>
        <script>
        (function() {
          var BASE_URL = #{base_url.to_json};
          var API_URL = BASE_URL + '/community-map/members.json';

          var isEmbed = (window.self !== window.top);
          var isMobile = window.innerWidth <= 600;

          // Hide branding when embedded
          if (isEmbed) {
            var header = document.getElementById('sidebar-header');
            if (header) {
              var brand = header.querySelector('.brand');
              if (brand) brand.style.display = 'none';
            }
            var backLink = document.querySelector('.back-link');
            if (backLink) backLink.style.display = 'none';
          }

          // Init map — centered on DACH region
          var map = L.map('map', { zoomControl: false }).setView([51.1657, 10.4515], 6);

          L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
            attribution: '&copy; <a href="https://osm.org/copyright">OSM</a> &copy; <a href="https://carto.com/">CARTO</a>',
            maxZoom: 19
          }).addTo(map);

          L.control.zoom({ position: 'topright' }).addTo(map);

          // Avatar icon for map markers
          function createAvatarIcon(member) {
            var inner;
            if (member.avatar_url) {
              inner = '<img src="' + member.avatar_url + '" alt="" style="width:100%;height:100%;object-fit:cover;border-radius:50%">';
            } else {
              inner = '<span style="font-size:13px;font-weight:700;color:#fff">' + (member.initials || '?') + '</span>';
            }
            return L.divIcon({
              className: '',
              html: '<div style="width:38px;height:38px;background:#6c8cff;border-radius:50%;display:flex;align-items:center;justify-content:center;box-shadow:0 2px 12px rgba(108,140,255,.4);border:2px solid rgba(255,255,255,.2);cursor:pointer;overflow:hidden">' + inner + '</div>',
              iconSize: [38, 38],
              iconAnchor: [19, 19]
            });
          }

          var allMembers = [];
          var markers = [];
          var activeItem = null;
          var pinSvg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/></svg>';

          function renderList(members) {
            var list = document.getElementById('member-list');
            var count = document.getElementById('count');
            var sheetTitle = document.getElementById('sheet-title');
            var countText = members.length + ' Mitglied' + (members.length !== 1 ? 'er' : '');

            count.textContent = countText;
            if (sheetTitle) sheetTitle.textContent = countText;

            list.innerHTML = members.map(function(m, i) {
              var avatarContent;
              if (m.avatar_url) {
                avatarContent = '<img src="' + m.avatar_url + '" alt="">';
              } else {
                avatarContent = m.initials || '?';
              }
              var profileUrl = BASE_URL + '/u/' + m.username;

              return '<div class="member-item" data-index="' + i + '">' +
                '<div class="member-avatar">' + avatarContent + '</div>' +
                '<div class="member-info">' +
                  '<div class="member-name"><a href="' + profileUrl + '" target="_blank">' + m.name + '</a></div>' +
                  (m.position ? '<div class="member-position">' + m.position + '</div>' : '') +
                  '<div class="member-city">' + pinSvg + m.city + '</div>' +
                '</div></div>';
            }).join('');

            list.querySelectorAll('.member-item').forEach(function(item) {
              item.addEventListener('click', function(e) {
                if (e.target.tagName === 'A') return; // let profile links through
                var idx = parseInt(this.dataset.index);
                var m = members[idx];
                map.setView([m.lat, m.lng], 12);
                markers.forEach(function(mk) { if (mk._member === m) mk.openPopup(); });

                if (activeItem) activeItem.classList.remove('active');
                this.classList.add('active');
                activeItem = this;

                if (isMobile) setSheetState('peek');
              });
            });
          }

          function updateMarkers(members) {
            markers.forEach(function(m) { map.removeLayer(m); });
            markers = [];

            members.forEach(function(m) {
              var profileUrl = BASE_URL + '/u/' + m.username;
              var avatarHtml;
              if (m.avatar_url) {
                avatarHtml = '<img src="' + m.avatar_url + '" style="width:40px;height:40px;border-radius:50%;object-fit:cover">';
              } else {
                avatarHtml = '<div style="width:40px;height:40px;background:rgba(108,140,255,.15);color:#6c8cff;border-radius:50%;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:14px">' + (m.initials || '?') + '</div>';
              }

              var popup = '<div style="min-width:200px">' +
                '<div style="display:flex;align-items:center;gap:10px;margin-bottom:8px">' +
                  avatarHtml +
                  '<div>' +
                    '<a href="' + profileUrl + '" target="_blank" style="font-size:15px;font-weight:700;color:#e8ecf1;text-decoration:none">' + m.name + '</a>' +
                    (m.position ? '<br><span style="color:#6c8cff;font-size:12px">' + m.position + '</span>' : '') +
                  '</div>' +
                '</div>' +
                '<div style="color:#8b95a5;font-size:12px;display:flex;align-items:center;gap:4px">' +
                  '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/></svg>' + m.city +
                '</div>' +
                (m.about ? '<div style="color:#8b95a5;font-size:12px;margin-top:6px;padding-top:6px;border-top:1px solid #333842;line-height:1.4">' + m.about.substring(0, 200) + (m.about.length > 200 ? '&hellip;' : '') + '</div>' : '') +
                '</div>';

              var mk = L.marker([m.lat, m.lng], { icon: createAvatarIcon(m) })
                .bindPopup(popup, { maxWidth: 280 }).addTo(map);
              mk._member = m;
              markers.push(mk);
            });

            if (markers.length) {
              map.fitBounds(L.featureGroup(markers).getBounds().pad(0.15));
            }
          }

          function applyFilters() {
            var searchEl = isMobile ? document.getElementById('mobile-search') : document.getElementById('desktop-search');
            var q = searchEl ? searchEl.value.toLowerCase() : '';
            var filtered = allMembers.filter(function(m) {
              return !q ||
                m.name.toLowerCase().indexOf(q) !== -1 ||
                m.city.toLowerCase().indexOf(q) !== -1 ||
                (m.position && m.position.toLowerCase().indexOf(q) !== -1);
            });
            renderList(filtered);
            updateMarkers(filtered);
          }

          document.getElementById('desktop-search').addEventListener('input', applyFilters);
          document.getElementById('mobile-search').addEventListener('input', applyFilters);

          // === Mobile Bottom Sheet ===
          var sidebar = document.getElementById('sidebar');
          var handle = document.getElementById('sheet-handle');
          var sheetState = 'peek';

          function setSheetState(state) {
            sheetState = state;
            sidebar.className = 'sidebar sheet-' + state;
            if (state !== 'peek') map.invalidateSize();
          }

          if (handle) {
            handle.addEventListener('click', function(e) {
              if (e.target.tagName === 'INPUT') return;
              if (sheetState === 'peek') setSheetState('half');
              else if (sheetState === 'half') setSheetState('full');
              else setSheetState('peek');
            });

            var startY = 0, currentY = 0, isDragging = false;
            handle.addEventListener('touchstart', function(e) {
              startY = e.touches[0].clientY; isDragging = true;
              sidebar.style.transition = 'none';
            }, { passive: true });

            handle.addEventListener('touchmove', function(e) {
              if (!isDragging) return;
              currentY = e.touches[0].clientY;
            }, { passive: true });

            handle.addEventListener('touchend', function() {
              if (!isDragging) return;
              isDragging = false;
              sidebar.style.transition = '';
              var diff = startY - currentY;
              if (Math.abs(diff) < 20) return;
              if (diff > 50) {
                if (sheetState === 'peek') setSheetState('half');
                else if (sheetState === 'half') setSheetState('full');
              } else if (diff < -50) {
                if (sheetState === 'full') setSheetState('half');
                else if (sheetState === 'half') setSheetState('peek');
              }
            });
          }

          map.on('click', function() {
            if (isMobile && sheetState !== 'peek') setSheetState('peek');
          });

          window.addEventListener('resize', function() {
            isMobile = window.innerWidth <= 600;
            map.invalidateSize();
          });

          // === Load Data ===
          function loadData(data) {
            allMembers = data;
            applyFilters();
            var loading = document.getElementById('loading');
            loading.classList.add('hidden');
            setTimeout(function() { loading.remove(); }, 300);
          }

          fetch(API_URL)
            .then(function(r) {
              if (!r.ok) throw new Error('HTTP ' + r.status);
              return r.json();
            })
            .then(loadData)
            .catch(function(err) {
              console.error('Community Map: Failed to load members', err);
              document.getElementById('loading').innerHTML =
                '<div style="text-align:center;padding:40px">' +
                '<div style="font-size:24px;margin-bottom:12px">&#x26A0;&#xFE0F;</div>' +
                '<div style="color:var(--cm-text)">Mitglieder konnten nicht geladen werden</div>' +
                '<div style="color:var(--cm-text-secondary);font-size:13px;margin-top:8px">' + err.message + '</div>' +
                '<a href="javascript:location.reload()" style="color:var(--cm-accent);font-size:13px;margin-top:12px;display:inline-block">Erneut versuchen</a>' +
                '</div>';
            });

          setTimeout(function() { map.invalidateSize(); }, 100);
        })();
        </script>
        </body>
        </html>
      HTML
    end
  end
end
