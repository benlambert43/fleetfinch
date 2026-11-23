(function () {
  "use strict";

  var storageKey = "fleetfinch-theme";
  var root = document.documentElement;
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  var preference = readSaved();

  function readSaved() {
    try {
      var saved = window.localStorage.getItem(storageKey);
      return saved === "light" || saved === "dark" ? saved : "auto";
    } catch (error) {
      window.console.warn("Could not read the saved theme", error);
      return "auto";
    }
  }

  function save() {
    try {
      window.localStorage.setItem(storageKey, preference);
    } catch (error) {
      window.console.warn("Could not save the theme", error);
    }
  }

  function apply() {
    if (preference === "dark" || (preference === "auto" && darkQuery.matches)) {
      root.classList.add("theme-dark");
    } else {
      root.classList.remove("theme-dark");
    }
  }

  function syncInputs() {
    var inputs = document.querySelectorAll(".theme-input");
    for (var i = 0; i < inputs.length; i++) {
      inputs[i].checked = inputs[i].value === preference;
    }
  }

  apply();

  if (typeof darkQuery.addEventListener === "function") {
    darkQuery.addEventListener("change", apply, false);
  }

  window.addEventListener(
    "storage",
    function (event) {
      if (event.key === storageKey) {
        preference = readSaved();
        apply();
        syncInputs();
      }
    },
    false
  );

  document.addEventListener(
    "DOMContentLoaded",
    function () {
      var inputs = document.querySelectorAll(".theme-input");
      for (var i = 0; i < inputs.length; i++) {
        inputs[i].addEventListener(
          "change",
          function (event) {
            preference = event.target.value;
            save();
            apply();
          },
          false
        );
      }
      syncInputs();
    },
    false
  );
})();
