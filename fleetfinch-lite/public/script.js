(function () {
  "use strict";

  var root = document.documentElement;
  root.classList.remove("no-js");
  root.classList.add("js");

  document.addEventListener("touchstart", function () {}, false);

  var storageKey = "fleetfinch-prerequisites";
  var checkboxes = document.querySelectorAll(".checklist-input");
  var installButton = document.querySelector(".install-button");
  var installError = document.getElementById("install-error");

  if (!installButton || !installError || checkboxes.length === 0) {
    return;
  }

  function readSaved() {
    try {
      var saved = JSON.parse(window.localStorage.getItem(storageKey));
      return saved && typeof saved === "object" ? saved : {};
    } catch (error) {
      window.console.warn("Could not read saved prerequisites", error);
      return {};
    }
  }

  function save() {
    var state = {};
    for (var i = 0; i < checkboxes.length; i++) {
      state[checkboxes[i].value] = checkboxes[i].checked;
    }
    try {
      window.localStorage.setItem(storageKey, JSON.stringify(state));
    } catch (error) {
      window.console.warn("Could not save prerequisites", error);
    }
  }

  function allChecked() {
    for (var i = 0; i < checkboxes.length; i++) {
      if (!checkboxes[i].checked) {
        return false;
      }
    }
    return true;
  }

  function update() {
    var ready = allChecked();
    installButton.setAttribute("aria-disabled", ready ? "false" : "true");
    if (ready) {
      installError.hidden = true;
    }
  }

  var saved = readSaved();
  for (var i = 0; i < checkboxes.length; i++) {
    checkboxes[i].checked = saved[checkboxes[i].value] === true;
    checkboxes[i].addEventListener(
      "change",
      function () {
        save();
        update();
      },
      false
    );
  }

  installButton.addEventListener(
    "click",
    function (event) {
      if (!allChecked()) {
        event.preventDefault();
        installError.hidden = true;
        window.setTimeout(function () {
          installError.hidden = false;
        }, 0);
      }
    },
    false
  );

  update();
})();
