import DiscourseRoute from "discourse/lib/discourse-route";

export default class CommunityMapRoute extends DiscourseRoute {
  beforeModel() {
    // no-op, just needs to exist so Ember handles this route
  }

  setupController(controller) {
    controller.set("embedUrl", "/community-map/embed");
  }
}
