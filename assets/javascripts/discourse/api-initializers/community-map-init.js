import { apiInitializer } from "discourse/lib/api";

export default apiInitializer("1.0.0", (api) => {
  // Add body class when on community-map route
  api.onPageChange((url) => {
    if (url === "/community-map") {
      document.body.classList.add("community-map-page");
    } else {
      document.body.classList.remove("community-map-page");
    }
  });
});
