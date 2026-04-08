# frozen_string_literal: true

# name: discourse-community-map
# about: Interactive community map showing member locations on a Leaflet.js map
# version: 1.1.0
# authors: Pat (Out Of The Box Science)
# url: https://github.com/oxscience/discourse-community-map
# required_version: 2.7.0

enabled_site_setting :community_map_enabled

register_asset "stylesheets/community-map.scss"

after_initialize do
  module ::DiscourseCommunityMap
    PLUGIN_NAME = "discourse-community-map"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseCommunityMap
    end
  end

  require_relative "app/controllers/community_map_controller"

  DiscourseCommunityMap::Engine.routes.draw do
    get "/embed" => "community_map#show"
    get "/members" => "community_map#members"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseCommunityMap::Engine, at: "/community-map-api"
  end
end
