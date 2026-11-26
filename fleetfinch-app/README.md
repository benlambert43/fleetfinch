This is the main application for Fleet Finch that will be installed on the iOS device.

It will contain:

- A cleanup utility designed to remove as many stock apps and stock services as possible.
- A patch utility designed to lift and replace the dependencies on the stock system and cydia tooling into this application, then track and update them here in the fleetfinch app.
- A cleanup utility to remove the Cydia app and remove software components related to Cydia.
- A patcher utility to update as much software on the device as possible, including certificate updates and Safari patches.
- An app store where users can download apps, software tools and extensions
- Additional settings that the stock settings app doesn't have

## Building

Fleet Finch is built with Theos from `~/.fleetfinch/theos`, the same way as [Finch Logs](../fleetfinch-logs/README.md), with `TARGET = iphone:clang:9.3:9.0` and `ARCHS = armv7`. From the repository root, `npm run build:app` runs `make package` here and writes `packages/com.fleetfinch.app_<version>_iphoneos-arm.deb`. Install it with `dpkg -i` on the device, then run `uicache` the first time, or whenever `Info.plist` changes, so the Home screen shows the icon.

The app's bundle identifier is `com.fleetfinch.app`, its executable is `FleetFinch`, and the Home screen shows it as Fleet Finch.

## Screens

The app opens on a tab bar with four screens. For now every feature is a placeholder: its row opens a page that says what it will do and that it is coming soon.

| Tab       | Source                        | What it will hold                                                                                                                                                                                        |
| --------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Home      | `app/FFHomeController.m`      | The device's name, model and iOS version, which are real                                                                                                                                                 |
| Utilities | `app/FFUtilitiesController.m` | A summary of what has been removed, patched and updated, not yet checked, then the stock apps and services cleanup, the Cydia removal, the system dependencies patcher, and the software updates patcher |
| Apps      | `app/FFAppsController.m`      | The app store's apps, tools and extensions, and what has been installed from it                                                                                                                          |
| Settings  | `app/FFSettingsController.m`  | The settings the stock Settings app does not have, and the app's version and build, which are real                                                                                                       |

Every screen is a grouped list built by `app/FFListController.m`: a screen returns its sections from `buildSections`, each with a header, rows and a footer, and a row with an `about` text opens `app/FFPlaceholderController.m`. Rows are one line each, title on the left and value on the right, so they keep their height at iPhone width on iOS 9. `app/FFTheme.m` holds the tint color and draws the tab icons.

The icon is the finch on its branch, from `assets/finch.png` at the top of the repository, on a white a shade warmer than pure white, `#FFFCF7`. The launch images show the same finch in the middle of the screen on the same white. [Artwork](../README.md#artwork) in the main README says how the files in `app/Resources` are made.
