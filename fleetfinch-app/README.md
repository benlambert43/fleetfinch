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

The package also installs a root helper, `/usr/bin/fleetfinch`, built from `tool`, and two launch services that run it: `com.fleetfinch.app.helper`, which does what the app asks for, and `com.fleetfinch.app.reach`, which keeps the device reachable while it sleeps. `shared` holds what the app and the helper both use.

## Screens

The app opens on a tab bar with four screens. Stock Apps and Services under Utilities is real; every other feature is a placeholder for now: its row opens a page that says what it will do and that it is coming soon.

| Tab       | Source                        | What it will hold                                                                                                                                                                                                                                             |
| --------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Home      | `app/FFHomeController.m`      | The device's name, model and iOS version, which are real                                                                                                                                                                                                      |
| Utilities | `app/FFUtilitiesController.m` | A summary of what has been removed, patched and updated, of which the stock apps and services line is real, then the stock apps and services cleanup, which is real too, the Cydia removal, the system dependencies patcher, and the software updates patcher |
| Apps      | `app/FFAppsController.m`      | The app store's apps, tools and extensions, and what has been installed from it                                                                                                                                                                               |
| Settings  | `app/FFSettingsController.m`  | The settings the stock Settings app does not have, and the app's version and build, which are real                                                                                                                                                            |

Every screen is a grouped list built by `app/FFListController.m`: a screen returns its sections from `buildSections`, each with a header, rows and a footer. A row with an `about` text opens `app/FFPlaceholderController.m`, a row with an `action` runs it when tapped, and a button row is drawn in the tint color, or in red when it removes something. Rows are one line each, title on the left and value on the right, so they keep their height at iPhone width on iOS 9. `app/FFTheme.m` holds the tint color and draws the tab icons.

The icon is the finch on its branch, from `assets/finch.png` at the top of the repository, on a white a shade warmer than pure white, `#FFFCF7`. The launch images show the same finch in the middle of the screen on the same white. [Artwork](../README.md#artwork) in the main README says how the files in `app/Resources` are made.

## Cleanup

Stock Apps and Services (`app/FFCleanupController.m`) removes what `app/Resources/Cleanup.plist` lists and can put all of it back. The list is made of groups, and a run goes through them in the order they are written: the stock apps first, then files on the system volume that nothing needs any more, then launch services. A group may carry a `models` list, and is then left out on any other model: the cellular radio software, for one, is only unused on an iPad without a cellular radio. Removing the apps first takes away most of what asks the background services for work, so the services can be judged with their clients gone.

The page shows what is removed and what is still installed with the space each takes, the free space on the system volume, each group, a red Remove Stock Apps and Services button, and Put Everything Back once something has been removed. A tap on a group lists what is in it (`app/FFCleanupGroupController.m`) with buttons to remove or put back that group alone. Every button asks first.

### How a removal is made

The app runs as `mobile` and cannot change the system volume. It writes a request file into `/private/var/mobile/Library/FleetFinch/Requests`, and launchd, which watches that folder, starts `fleetfinch serve` as root. The helper posts `com.fleetfinch.app.cleanup.changed` as it goes and the page follows it through `/private/var/FleetFinch/progress.plist`.

For each thing on the list the helper:

1. Makes sure the system volume can be written. A jailbroken start now and then leaves it read-only (about one in twenty on the test device); the helper remounts it with `/sbin/mount -u -w /`, and stops with a message if that does not work.
2. Refuses it unless it is on the list, sits in one of the system volume's folders, and is not something the device needs to start, to be reached, or to keep Safari, Settings, SpringBoard and Fleet Finch (`FFKeptTrees` and `FFKeptFiles` in `tool/FFCleaner.m`).
3. Copies it to `/private/var/FleetFinch/Removed`, under the same path it had, and compares the copy with the original. The copy keeps the file system's compression, so it goes back at the size it had.
4. Writes its path to the batch's list in `/private/var/FleetFinch/Batches`, then deletes the original.

`/private/var/FleetFinch/cleanup.plist` records each run as a batch, and the batch is written there before its first change, so a run that is cut short is still known. `/private/var/FleetFinch/cleanup.log` keeps a line for everything done.

### Launch services

A launch service is the one kind of thing whose removal can make the device unreachable while it is still running, so it gets its own treatment. A definition that launchd does not load on this hardware (its `LimitLoadToHardware` or `LimitLoadFromHardware` rules the device out) is removed as a plain file, because several definitions can share one label and unloading by the unused file would stop the one that is running. The helper waits until the processors are calm, unloads the one service with `launchctl unload`, and watches the processors for nine seconds. If they stay full, it loads the service again and leaves it where it is. That is what happens when other parts of iOS depend on the service: on iOS 9.3.5, unloading `com.apple.identityservicesd` makes eight other processes, SpringBoard and the Wi-Fi service among them, ask for it about fifty times a second each, which fills both processors and leaves no time for anything launchd starts at background priority, the SSH service included.

The helper's launch service runs at the highest priority launchd gives (`Nice` -20, `ProcessType` `Interactive`) and the helper fixes its own priority above ordinary services, so it can still load a service back, or put a batch back, on a device in that state.

### After a restart

A batch that has not been through a restart is on trial. The helper runs at every start, and if such a batch exists it waits two minutes and then checks, up to seven times twenty seconds apart, that the Home screen is running and has stayed up, the device has a network address, the SSH port answers if it did before, and the processors are not still full. The Home screen counts as having stayed up once it is two and a half minutes old and iOS's watchdog has written no `stacks+backboardd` report since the start: without a service it waits for, iOS kills and restarts the Home screen every two minutes, and restarts the device after the second time. If that holds, the batch is marked as through a restart. If it does not, the helper puts the batch back, and restarts the device once if it still cannot be reached.

### Putting things back

Put Everything Back, or Put This Group Back on a group's page, copies each thing from `/private/var/FleetFinch/Removed` to where it was, compares the copy with the kept one byte for byte, and only then deletes the kept one. The last batch goes back first and each batch backwards, so a program is back before the launch definition that runs it. A definition that loads on this hardware is loaded with `launchctl load` as soon as it is back, and the Home screen's list of apps is made again once apps have returned. Restart the device afterwards, so that every service starts the way it does on the stock system.

The Home screen's arrangement goes back too. iOS forgets where an app's icon was when the app goes, so before a run takes apps away the helper asks SpringBoard for its arrangement and keeps it in `/private/var/FleetFinch/arrangement.plist`. It does that only while every listed app is still installed, so a later run cannot replace it with a half-empty Home screen. When a put-back has returned apps and none of the listed apps is still removed, the helper hands the arrangement back to SpringBoard and reads it again until every returned app is shown in its place, then deletes its copy (`tool/FFArrangement.m`). It uses the calls Apple's own icon service uses for iTunes, `SBGetIconState` and `SBSetIconState`, which SpringBoard allows to a program with the `com.apple.springboard.iconState` entitlement. The apps come back with the blue dot iOS gives a new app. A device that was cleaned up by a build without this has nothing saved, and its apps return where iOS puts them.

While the helper works, in either direction, the SSH service can answer late or not at all for a minute or two at a time. The helper runs above everything else, and this jailbreak's SSH service is started by launchd at background priority, so it waits. It answers again by itself.

### Reachable while asleep

An iPad on battery goes to sleep a few seconds after its screen turns off, and iOS switches the Wi-Fi chip off for the sleep unless some program has asked the Wi-Fi service to keep it joined. On the stock system the push service, `apsd`, asks for that, but only while other services are registered with it. Once the list is removed nothing asks, and the device drops off the network every time it sleeps: the test iPad could not be reached for 53 minutes, until a timer of iOS's own woke it. No single service is the cause, so trying services one at a time does not find it, and putting `apsd` back alone changes nothing, because with nothing registered it stops by itself after seventeen seconds.

So Fleet Finch asks for it itself. The launch service `com.fleetfinch.app.reach` runs `fleetfinch keep-reachable` (`tool/FFStayJoined.m`) from every start. It makes the request `apsd` made, `WiFiManagerClientSetWoWState`, and stays running to hold it: the Wi-Fi service keeps one request for each program, and Wi-Fi stays joined while any of them wants it. It takes about 1.5 MB of memory and no processor time. With it a sleeping device stays joined, a packet addressed to it wakes it, it answers, and it goes back to sleep about five seconds later, as on the stock system. `fleetfinch cleanup check` says which way the setting is.

On battery a connection can still fail now and then, as it can on the stock system: iOS goes back to sleep five seconds after a wake whatever is in progress, so a connection that arrives in the instant the device falls asleep gets no answer until the caller gives up. The next try is answered. A device on its charger does not sleep.

### From a shell

| Command                                          | What it does                                                                                     |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| `fleetfinch cleanup status`                      | Each group with how much of it is installed, removed or not on this device, and each batch       |
| `fleetfinch cleanup list [GROUP]`                | Each thing on the list with its state and size                                                   |
| `fleetfinch cleanup check`                       | Whether the device can be reached, awake and asleep, and any launch service without its program  |
| `fleetfinch cleanup remove [GROUP \| PATH ...]`  | Removes the groups or listed paths named, or everything listed; the work is handed to the helper |
| `fleetfinch cleanup restore [GROUP \| PATH ...]` | Puts them back, or everything that was removed                                                   |

### What the list holds

The list has 4,076 things in 23 groups, in the order a run takes them. A thing is listed once: either whole or in parts, never both.

| Group                                   | Kind     | Things | What it is                                                                                                                                                                                                                                                              |
| --------------------------------------- | -------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stock Apps                              | Apps     | 25     | Every app iOS put on the Home screen except Safari and Settings.                                                                                                                                                                                                        |
| Hidden Apps                             | Apps     | 45     | Apps with no icon that the removed apps and services put on the screen: sign-in dialogs, share sheets, pickers and set-up screens.                                                                                                                                      |
| iOS Update Files                        | Files    | 1      | The files iOS keeps to install a software update over the air. iOS 9.3.5 is the last version for this device.                                                                                                                                                           |
| Typing Data for Other Languages         | Files    | 69     | The dictionaries and prediction data for typing in languages other than English, and the Japanese and Chinese input engine. English stays.                                                                                                                              |
| Wallpapers and Ringtones                | Files    | 3      | The stock wallpaper pictures, the moving wallpapers and the ringtones. The wallpaper in use is kept.                                                                                                                                                                    |
| Leftovers of Removed Apps               | Files    | 4      | Files that only the removed apps and features used: the Music store's pages, the voice trigger data and the Apple Watch fonts.                                                                                                                                          |
| Fonts Not in Use                        | Files    | 71     | The fonts for scripts other than Latin (Chinese, Japanese, Korean, Arabic, Hebrew, the Indian scripts and others) and the display fonts the removed apps used. Pages in those scripts show empty boxes afterwards. The system font, the usual web fonts and emoji stay. |
| Other Things Nothing Uses               | Files    | 7      | Data and frameworks that no program on the device links, opens or has read: the word-splitting data for Chinese, Japanese and Thai, raw camera support, the update progress pictures, and the OpenCL, voice trigger, slideshow and iWork preview frameworks.            |
| Map Drawing Data                        | Files    | 1,163  | The icons, road shields, styles and fonts Maps drew its maps with. The parts of the framework that location services read stay.                                                                                                                                         |
| Speaking Voices                         | Files    | 36     | The voices that read text aloud in languages other than American English.                                                                                                                                                                                               |
| Handwriting Data                        | Files    | 6      | The models for recognising handwritten Chinese and other handwriting input.                                                                                                                                                                                             |
| Photo Effects                           | Files    | 19     | The pictures the Photos app's editing effects were made from.                                                                                                                                                                                                           |
| Sounds of Removed Apps                  | Files    | 43     | The alert tones of Messages, Mail, Calendar, the phone, payments, navigation and the Apple Watch. The keyboard, lock, power, screenshot and other system sounds stay.                                                                                                   |
| Cellular Radio Software                 | Files    | 3      | The program that runs the cellular radio and its two launch definitions, which launchd does not load on a Wi-Fi iPad 2.                                                                                                                                                 |
| Translations                            | Files    | 2,198  | The wording of iOS in languages other than English, and the spelling dictionaries of those languages. Folders that take no space of their own are left.                                                                                                                 |
| Leftovers of iCloud and Online Services | Files    | 91     | Small programs, sign-in plug-ins, settings panels and lock screen plug-ins of iCloud, Apple ID, Find My iPad, Wallet, Mail, the social networks and the Apple Watch, which nothing on the device has used.                                                              |
| Software Update and Diagnostics         | Services | 20     | The services that look for updates to iOS and to its time zone data, and that gather and send usage and diagnostic reports to Apple. Crash reports are still written.                                                                                                   |
| Messages, FaceTime and Calls            | Services | 12     | The services behind iMessage, FaceTime, call history and the blocked callers list. The identity service they share stays, because Wi-Fi, location and the Home screen ask for it without pause when it is gone.                                                         |
| iCloud, Apple ID and Push               | Services | 28     | The services behind iCloud, Find My iPad, Family Sharing, Apple ID sign-in, iCloud backup and Apple's push notifications.                                                                                                                                               |
| Stores, Media Library and Sync          | Services | 38     | The services behind the App Store, iTunes Store, Music, Game Center, Home, Health, Maps, Tips, iTunes sync, the stores' copy protection, and the calendar, contacts and photo libraries of the removed apps.                                                            |
| Other Services Not in Use               | Services | 46     | Services of features nothing on this device uses: the set-up helper, device management, VPN and hotspot helpers, search, shared web passwords, asset downloads, usage prediction, storage on camera adapters and the location extras that only apps used.               |
| Cellular Helpers                        | Services | 6      | The helpers the cellular service starts for carrier settings and carrier updates, on an iPad without a cellular radio. The cellular service itself stays, because the Home screen asks for it without pause when it is gone.                                            |
| Programs of Removed Services            | Services | 142    | The programs those services ran, each used by no launch service that is left.                                                                                                                                                                                           |

### What stays

Four services were tried, looked removable at first, and are kept. Each shows a way a removal can go wrong that asking whether SSH answers a minute later does not show.

| Service                       | What happens without it                                                                                                                                                                                                          |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `com.apple.identityservicesd` | Eight processes that use it ask for it about fifty times a second each. Both processors fill within fifteen seconds and SSH stops answering. Loading it again cures it in twelve seconds                                         |
| `com.apple.imagent`           | No load to speak of, but the Home screen asks for it once a second for good and writes four log lines each time                                                                                                                  |
| `com.apple.accountsd`         | Nothing until the next restart. Then `identityservicesd` cannot serve the Home screen, iOS's watchdog kills the Home screen every two minutes, and the device restarts itself after the second time, while SSH goes on answering |
| `com.apple.CommCenter`        | Nothing while it is only unloaded. After the next restart the Home screen asks for it nine times a second for good, on an iPad that has no cellular radio                                                                        |

Left alone without a trial, because of what they do: profiles and certificates (`profiled`), the activation state read at every start (`mobileactivationd`), app installs (`installd`, `misagent`), the USB services of lockdown, crash reports, accessibility, the keyboard, sound and video, networking and time, the cache and storage maintenance jobs, the migration that a start can wait for (`datamigrator`), and the battery log behind the Battery pane of Settings. The Latin fonts, the fonts web pages ask for, emoji and the two other English wordings (`en_GB`, `en_AU`) stay as well.

Location Services and Bluetooth stay because they are wanted, not because the device needs them: `locationd`, and `BTServer` with its four helpers, `BlueTool` and the four accessory services of the dock connector (`iapd`, `iap2d`, `iapauthd`, `iaptransportd`). The now-playing service (`mediaremoted`) stays with them, because it hands the play and pause buttons of a headset or speaker to the app that is playing. The fourth test removed all of these without a fault. They were put back afterwards and taken off the list. Together they cost 20 MB of the system volume and about 24 MB of free memory.

### What the list was tested on

Everything on the list was removed from an iPad 2 (`iPad2,1`) on iOS 9.3.5, four ways:

1. The launch services one at a time, with restarts in between, to find the ones that have to stay.
2. Group by group, and then what was left in one run of the button.
3. All of it put back with Put Everything Back, a restart, and then the whole list in one run of the button from that put-back system, with a restart after it.
4. After a second look at what still ran: 26 more services tried one at a time, of which one has to stay, and 91 small leftover files. Then everything put back once more, a restart, and the whole list of 4,100 in one run, with a restart after it.

The fourth test also removed Location Services, Bluetooth and the now-playing service, 24 of those 4,100 things. They were put back afterwards and taken off the list. The table shows the device after that, four minutes after a restart.

Safari, Settings, the keyboard, video with sound and SSH were checked afterwards and through restarts, and SSH was checked with the device asleep on battery. On any other model or version the page says so before it removes anything. The typing data group keeps English only, and a web page in a script whose font is removed shows boxes in place of letters.

|                           | Before            | After                                   |
| ------------------------- | ----------------- | --------------------------------------- |
| Free on the system volume | 105 MB (95% full) | 1,059 MB (48% full)                     |
| Apps in `/Applications`   | 77                | 7                                       |
| Launch definitions        | 254               | 105                                     |
| Launch services running   | 96 to 112         | 53                                      |
| Processes running         | 106 to 120        | 60 to 62                                |
| Memory in use             | 382 to 410 MB     | 275 MB                                  |
| Memory free               | 27 to 61 MB       | 191 MB                                  |
| Time for the whole list   |                   | 20.5 minutes to remove, 7.5 to put back |

What the third test showed:

- Put Everything Back put all 3,958 things of the list as it then was back with no problem reported. The 30,361 files, folders and links in them were compared with a listing of the kept copies taken beforehand: none missing, none extra, and every one with the same type, permissions, owner, group, link target and length. The 16,456 of them that were still on the system volume when it was listed in the afternoon have the same number of blocks as then, so the file system's compression came back with them. Extended attributes and file flags were not compared.
- After the restart that followed, launchd knew every launch service it knew on the stock system, `/System/Library/LaunchDaemons` held the same 254 definitions, eight of the apps that had been put back were opened and ran, and a Japanese web page drew in Japanese again.
- The one run of the button removed all 3,958 things with nothing refused and no service loaded back, and the helper's own check passed it after the restart.
- iOS wrote one `ExcResource_fleetfinch` report during the long run, a note that the helper had been busy for three minutes (`NON-FATAL CONDITION`). It is not a crash.

What the fourth test showed:

- The Home screen's arrangement comes back. With the stock arrangement set, the apps were removed and put back, by group and with the whole list: each time SpringBoard's arrangement read the same as the one saved, a dock of four and pages of nineteen and five icons, also after the restart that followed. Putting back a group without apps left an arrangement changed by hand alone.
- The cellular service passed while it was only unloaded and failed after a restart, so a removal is not judged until the log has been watched after a restart.
- A video played with its sound going to the speaker without the stores' copy protection and the now-playing service.
- Location Services and Bluetooth can be removed: without them the Location Services pane of Settings still opens, Safari cannot give a page the position, and Settings shows Bluetooth as unavailable. Put back and through a restart, both worked again: a position came accurate to 65 m, with `geod` and the map drawing data still removed, and Settings showed Bluetooth on and discoverable. No Bluetooth accessory was paired.
- Without the now-playing service a remote pause or play command, which is what a headset's button becomes, was accepted and never reached the app that was playing. With the service back each command arrived and the player followed it, also after a restart.
- After they were put back, a run of the whole list removed nothing, and naming any of them to `fleetfinch cleanup remove` was refused.
- The one run removed 4,099 things and freed 961 MB with nothing refused and no service loaded back, the helper's own check passed it after the restart, and port 22 answered all 53 probes during it. During the put-back before it port 22 missed 5 of 18.
- Of the services that stay, `identityservicesd` still tries to fetch its settings from Apple at every start and gives up after a set number of tries.
- Left alone overnight on battery with the whole list removed, the device slept for five and a quarter hours, in stretches of up to thirty minutes, and the first SSH connection after that was answered in two seconds. With Location Services and Bluetooth back it answered again after ten quiet minutes on battery.

Not tested: the page at iPhone width, any other model, and a Bluetooth accessory in use. The commands of a headset's buttons were sent by a tool on the device, not over Bluetooth.

[cleanup-log.txt](cleanup-log.txt) is the running record of those tests: every command sent to the iPad, what came back, and the verdict for each service.
