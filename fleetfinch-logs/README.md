# Finch Logs

Finch Logs is a service and an app for jailbroken iOS 9 devices. The service starts with the device and keeps a detailed record of what the system, its services and its apps are doing. The app reads that record on the device, and FleetFinch Developer reads it from a computer.

It is written in Objective-C against the iOS 9.3 SDK and built with Theos for `armv7`, so it runs on every device that iOS 9.3.5 and 9.3.6 support.

## What it records

Each log is a folder of plain text files, one file for each hour.

| Log        | What goes in it                                                                                                                                                                                    | Where it comes from                                                                                    |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| System Log | Every message the system log receives, from the kernel, services and apps, with its sender and level                                                                                               | The system log daemon's own socket, `/var/run/lockdown/syslog.sock`                                    |
| Kernel     | What the kernel prints while the service is running, and whatever its message buffer still held when the service started                                                                           | `proc_kmsgbuf`, read every 5 seconds                                                                   |
| Boot       | Each start of the device: when, how long it was off, how soon the service was recording, the kernel and its boot arguments, and every process already running, placed at the moment it began       | `sysctl`, the process table and launchd                                                                |
| Processes  | Every process that starts or exits, with its parent, user, command line and launchd service, the programs it passed through on the way, how long it ran, and the processor time and memory it used | Kernel process events for every fork, exec and exit, checked against the process table every 5 seconds |
| Apps       | Apps opening and closing, which app comes to the front, and apps being installed, updated or removed                                                                                               | The process table, SpringBoard and the app folders                                                     |
| Services   | Services added to or removed from launchd, started and stopped, with the exit code or signal each ended with                                                                                       | launchd's own job list                                                                                 |
| Resources  | Processor use for the device and each core, load, memory, free storage and disk traffic, network traffic and the battery; and the busiest and largest tasks                                        | Mach host statistics, `getmntinfo`, `getifaddrs` and IOKit, every 30 seconds                           |
| Power      | Sleep and wake with the reason for waking, charging, battery level, lock and display state                                                                                                         | IOKit power notifications and the battery driver                                                       |
| Network    | Interfaces, addresses and the Wi-Fi network as they change                                                                                                                                         | `getifaddrs`, CaptiveNetwork and the system's network change notifications                             |
| Events     | 81 notifications the system posts about its own state, memory pressure, and changes to the clock or time zone                                                                                      | Darwin notifications                                                                                   |
| Log Files  | New lines in the log files other parts of the system write for themselves                                                                                                                          | `/var/mobile/Library/Logs`, `/Library/Logs`, `/var/log`, `/var/logs` and five more such folders        |
| Dumps      | A line for each crash report or other dump the system wrote, and a copy of the file itself when it is 8 MB or smaller; a dump the system only moves or renames is noted, not copied again          | The same folders                                                                                       |
| Finch Logs | What the service itself did: starting, snapshots, imports, tidying, and anything that failed                                                                                                       | The service                                                                                            |

A snapshot is a full picture of one part of the system at one moment. The service takes fourteen of them when the device starts and again each day, and the ones that change often every six hours: Environment, Device, Processes, Services, Apps, Packages, Storage Volumes, Network, Power and Battery, Kernel Messages, Kernel Extensions, Kernel Settings (every `sysctl` value), Hardware Registry (the whole I/O Registry) and What Has Run (the report described under [What has run and what never has](#what-has-run-and-what-never-has)). Two more, What Is Installed and What Depends on What, are taken once a day and whenever something is installed or removed, as described under [What is installed](#what-is-installed) and [What depends on what](#what-depends-on-what).

## How the logs are kept

Everything is under `/var/mobile/Library/FinchLogs`.

| Path             | What it holds                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `live`           | The last day: `live/<log>/<date>_<hour>.log`, `live/snapshots/<kind>/<moment>.txt`, and copied dumps under `live/imports` |
| `archive`        | Older files, each compressed with gzip and kept under the same name and date                                              |
| `state`          | What the service knows between runs, and the status the app and the command line read                                     |
| `settings.plist` | Only the settings that differ from the defaults, written by the app                                                       |

A log line is `time`, `level`, `source` and `message`, separated by tabs. The time is the device's local time with its offset, such as `2026-11-24T14:17:31.113-07:00`. The level is one letter: `D`ebug, `I`nfo, `N`otice, `W`arning, `E`rror or `F`ault. Tabs, newlines and backslashes inside a field are written as `\t`, `\n` and `\\`.

A line goes into the file for the hour in which it is written. Nearly always that is the hour in its own time, but a line recorded late keeps its own time: the boot record places each process at the moment it began, and the system log hands over messages from before the service connected.

Every hour the service tidies the store:

- Files older than **24 hours** are compressed into the archive.
- Archived files older than **a week** are deleted.
- If the store still holds more than 1 GB, the oldest files are deleted first.

If a log file with the same name was archived before, which a clock set back can cause, the new one is added to it and nothing is overwritten.

The folders are created without data protection, so the service can write to them after a restart and before the device is first unlocked.

## The service

`/usr/bin/finchlog daemon` is the service. launchd starts it as root from `/Library/LaunchDaemons/com.fleetfinch.logs.daemon.plist` when the device starts, and starts it again if it ever stops. Installing the package starts it straight away.

On an iPad 2 it uses about 0.5% of one processor core while the device is awake, 1% while the app is open, and nothing while the device sleeps: it does not keep the device awake. Recording a process that starts and exits costs it about 3.6 milliseconds of processor. It holds about 1.7 MB of memory. Listing what is installed, and working out what depends on what, is done by a helper, which uses about 36 seconds of processor each time.

## How processes are followed

The service asks the kernel to tell it whenever any process forks, runs a new program or exits, and one thread does nothing but wait for that, at a fixed priority above ordinary programs so that it is not kept waiting when the device is busy. The moment a process forks, the thread finds the new child, starts following it too, and reads what it is. A command that lasts eight milliseconds is recorded with its real start, its command line and how long it ran.

- **A start line is written once the process has settled.** A new process often runs one or two programs on the way to its own: launchd starts every service through `xpcproxy`, and `sshd` through a script as well. The line names the last program and the ones before it, as in "started pid 3342 by launchd (pid 1) for com.openssh.sshd… by way of xpcproxy and sshd-keygen-wrapper". A process that changes program later gets a line of its own, "now runs".
- **A copy that never runs a program of its own is left out.** A shell forks a copy of itself for every command, and the copy is recorded only once it runs the command, or if it is still there after a second.
- **Lines carry the real times.** A start line is stamped with the moment the program began and an exit line with the moment it ended, to the millisecond, whenever the service gets round to writing them.
- **Processor time at exit** is read from the kernel when it still has it, which is about half the time for a short run. Memory is known only for a process that lived long enough to be sampled.
- **The process table is still compared** every five seconds, as a check on the events and for whatever was running before the service started.

Services are still found by comparing launchd's list, which is read again whenever launchd starts or loses a process. One that starts and stops between two readings is in Processes, with its name, and counted under What Has Run, but may be missing from Services.

iOS treats a launch daemon it has no rules for as idle: launchd may kill it without warning, and the kernel kills it if it uses more than 5 MB of memory. The service therefore tells launchd that it is always busy, which gets it a stop signal and time to save what it knows, and raises its own allowance to 16 MB. It stays far below that: the most it has been seen to hold is 2.1 MB.

## When the device sleeps

A locked iPad on battery goes to sleep about five seconds after it last woke, and the service's clocks stop with it: nothing is sampled and nothing is written until it wakes. The service does not keep the device awake and never wakes it.

Each sleep and each wake is a line in Power, with how long the device slept and what woke it. On waking, the service at once reads the kernel's messages and the process table, takes a resource sample, battery included, if the last one is more than 30 seconds old, and brings its status up to date, so a wake of a few seconds is recorded in full. Kernel messages carry no time of their own and are stamped when they are read, so what the kernel printed while going to sleep is stamped at the next wake. Going to sleep and waking make the kernel print about as much as its 4 KB buffer holds, so now and then the Kernel log loses the first lines of that and says so. The System Log has the same messages, all of them, with the system's own times.

Any packet sent to the device over Wi-Fi wakes it: a new connection, a keep-alive probe on an open SSH session, even the acknowledgement of something the device sent. The kernel prints the packet that woke it, which both the Kernel log and the System Log keep. `finchlog read --follow` and `finchlog tail -f` therefore print nothing from the moment the device starts going to sleep until it wakes: the acknowledgement of a line sent in that moment would reach the device after it slept and wake it again.

## What has run and what never has

The logs are deleted after a week, so the service also keeps a ledger that is never deleted: one record for each program, each launchd service and each app it has seen running. A record holds when it was first and last seen, how many runs were seen, how long it ran, the processor time it used, the most memory it held, what started it and, for a service, how it ended. The ledger is `state/usage.plist` in the store. It is saved at most every five minutes and whenever the service stops, and deleting it while the service is stopped starts the count again.

- **An app** is counted by its bundle identifier, **a service** by its launchd label and **a program** by the path of its executable. Labels that launchd makes afresh for each use, such as one `sshd` for every connection, are counted as one.
- A process counts for its program and for the service or app it runs as. A program is listed only when it has run outside any service or app, so a daemon appears once, under Services.
- **Never ran** is whatever is installed and has no record. What is installed comes from the list described under [What is installed](#what-is-installed): every app in `/Applications` and the app containers, every app extension and XPC service, and every program on the system volume. Services come from launchd: every one defined in its folders or known to it. App extensions and XPC services are listed with the services.
- **From** names the dpkg package that installed it. Whatever dpkg did not install is counted as part of iOS.
- **Size** is the space the thing takes on the volume, and for a service the space its program takes.
- A service that launchd does not load on this model of device says so.

The report says first how long the ledger has been counting, how much of that time the device was awake, and over how many starts of the device, because "never ran" means only that much. What the ledger cannot see:

- A run of a few milliseconds can end before it is named when the processor is saturated. It is then counted as "(too short to name)", with what started it, so the count shows how much is being missed. With the device idle, 300 of 300 eight-millisecond runs were named; with three busy loops on its two cores, 295 of 300, with 4 counted as too short to name and 1 missed.
- A script counts under its own path, as well as its interpreter's, when it is started by its `#!` line with a full path. A script handed to an interpreter by hand, as in `sh thing.sh`, counts as the interpreter only.
- Frameworks, plug-ins and libraries are not listed, because they are loaded into other programs and never run by themselves. [What depends on what](#what-depends-on-what) sorts them by whether anything that has run needs them.
- Until the service has listed what is installed, which it does within a few minutes of being installed, apps, extensions and programs that have never run are missing, and the report says so.
- Nothing is counted while the device sleeps, or in a start before the service is running, except that whatever is still running then is counted from the moment it began.

## What is installed

To decide what can be removed you need to know everything that is there, how much space it takes and what it offers to the rest of the system. The service keeps that list in `state/inventory.plist` and saves it as the What Is Installed snapshot. It walks the whole system volume, and the folders that hold apps installed from the App Store, and sorts what it finds into eight kinds.

| Kind                 | What is listed                                                                                                                    | What is written down about each                                                                                                                                                                                                               |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Apps                 | Every `.app`, wherever it is                                                                                                      | Its identifier and version, whether it is hidden from the Home screen, the URL schemes it opens, its background modes, the Mach services SpringBoard registers for it, and what is nested inside it                                           |
| App extensions       | Every `.appex`                                                                                                                    | The extension point it serves, and the app or framework it is inside                                                                                                                                                                          |
| Launch services      | Every definition in the launchd folders                                                                                           | What starts it, spelled out: at boot, kept running and on what condition, each Mach service it offers, each socket, each notification or other event, watched paths and timers. Also the user it runs as, its program and that program's size |
| XPC services         | Every `.xpc`                                                                                                                      | Its type, and what it is inside                                                                                                                                                                                                               |
| Frameworks           | Every `.framework`                                                                                                                | Whether its library is on disk or in the shared library cache, and what is nested inside it                                                                                                                                                   |
| Plug-ins and bundles | Every other folder that has an `Info.plist` or is named `.bundle`, `.plugin` or `.kext`, grouped by the folder it is in           | Its type                                                                                                                                                                                                                                      |
| Programs             | Every Mach-O executable and every executable script with a `#!` line that is not the main program of an app, extension or service | The interpreter of a script, and the launch services that run it                                                                                                                                                                              |
| Libraries            | Every Mach-O library on disk, and every library in the shared cache that is not a framework's own                                 | Where it is                                                                                                                                                                                                                                   |

Every item also has its size, its path, what it is nested inside, and where it came from: the dpkg package that installed it, or iOS.

- **A size is the space a thing takes on the volume**, which is what removing it would free. iOS keeps many files compressed, so this is often less than their length. A file that compresses to under 4 KB is kept inside the file system's own records and takes no space of its own, so a thing made only of such files shows as 0 bytes. The size of a folder includes what is nested inside it.
- **The whole volume is accounted for.** Files that belong to none of the eight kinds, such as fonts, sounds and language data, are added up by folder. The sizes of the kinds and of those folders add up to the space all the files take.
- **The shared library cache** is one file that holds most of the system's libraries. The list says which frameworks keep their library there and how much of the cache each takes. Such a library takes no space of its own and cannot be removed by itself, so removing a framework's folder frees only its other files.
- **Launch services are described from their definitions.** One whose `LimitLoadToHardware` or `LimitLoadFromHardware` key rules out this model of device is marked as not loaded on this model. One switched off in its file or in launchd's own record, `/var/db/com.apple.xpc.launchd/disabled.plist`, is marked as disabled. Whether launchd has a definition loaded at this moment is in the Services snapshot.

The walk reads about 64,000 files, and with the reading described under [What depends on what](#what-depends-on-what) it takes about two minutes on an iPad 2, so the service does not do it itself. It starts `finchlog inventory --save` as a helper at low priority and carries on recording, and a fault in the helper cannot stop the service. A minute after it starts, and every ten minutes from then on, the service starts the helper if nothing is listed yet, if the list is a day old, or if something was installed or removed, which it notices by the dates of the dpkg record, the launchd folders, `/Applications` and the other folders that programs live in. The helper does not keep the device awake: on battery it stops when the device sleeps and carries on at the next wake.

What the list does not show:

- **What uses a framework, a plug-in or a library.** That is the next section.
- **A change deep inside an app or a framework** at once. It is found at the next daily listing, or when the list is asked for again.
- **The data volume**, except for apps installed from the App Store.

## What depends on what

That something has never run is not enough to remove it, because something else may need it. Each time it lists what is installed, the helper also reads every program, library and plug-in, both the files on disk and the libraries inside the shared library cache, and writes down what each one depends on. The result is `state/dependencies.plist` and the What Depends on What snapshot.

| What is found  | How                                                                                                                                                                               | What it means                                                                       |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Links          | The libraries a file names in its load commands, found the way the loader finds them, search paths included                                                                       | The file cannot load without them, except the ones marked as needed only if present |
| Opened by name | The path of a library, a plug-in or a folder of plug-ins, found whole among the file's own strings                                                                                | The file may open it while it runs                                                  |
| Services named | A Mach service name that a launch service or an app offers, or the identifier of an XPC service, found the same way or listed in the program's entitlements as one it may look up | The program may talk to that service                                                |
| Entitlements   | Read from each program's code signature                                                                                                                                           | What iOS allows the program to do                                                   |

From these and from [what has run](#what-has-run-and-what-never-has), each library and plug-in is put in one of six groups:

1. **Loaded by a program that has run.** Links alone lead to it from a program in the ledger.
2. **May be opened by a program that has run.** The way to it from such a program goes through something opened by name.
3. **Needed only by programs that have never run.**
4. **Needed only by plug-ins that nothing names.**
5. **A plug-in that nothing names.** No program has its path, or its folder's, among its strings.
6. **Nothing found that needs it.**

The groups are worked out when the list is made, from the ledger as it stood then, so they are a day old at most. `finchlog depends NAME` prints one item: what it links, opens and names, what links, opens and names it, its entitlements and its group. In the app the same is on the item's page under What Is Installed.

- **The shared cache comes first, as it does for the loader.** A file on disk with the name of a library in the cache is never loaded. On the test iPad that is Cydia's `/usr/lib/libncurses.5.dylib`: `bash` links that name and gets the copy in the cache.
- **A link to a library that is not on the device is reported.** Seven programs and plug-ins on the test iPad cannot load for that reason, five of them app extensions that link `RadarCompose`, a framework that is not on the device.
- **The launch services, XPC services and apps** are each listed with the programs and libraries that name them.

What it cannot see:

- **A name the program puts together while it runs.** The keyboard's layouts, `KBLayouts_iPad.dylib`, 20 MB of the shared cache, are in the last group because TextInput makes the name from `KBLayouts_%@.dylib`. The last three groups are where to look, not a list of what is safe to remove.
- **Whether a name that is there is ever used.** A program that names a service may never call it.
- **Which plug-ins a program really loads.** Naming a folder of plug-ins counts as opening every plug-in in it.
- **Scripts.** What a shell script runs is not read.

## What it sees of a restart

Nothing that is not part of iOS runs until the jailbreak has done its work, so the service misses the first part of every start. On the test iPad, which uses the iocaste untether:

| After the device starts | What happens                                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------------------------------------ |
| 3.5 seconds             | launchd starts the first system services, the system log among them                                          |
| 31 seconds              | The jailbreak is in place, and launchd starts SpringBoard, Finch Logs and the other added daemons            |
| 51 to 57 seconds        | The added programs begin to run, Cydia's start-up script as late as the service, which writes its first line |

What the service has from before its first line:

- **Processes.** Every process still running, with the moment it began, back to launchd itself. A process that started and exited before the first line is not there.
- **System log.** The last 250 or so messages, which is all the system log keeps. They reached back to about 33 seconds after the start.
- **Kernel.** The last 4 KB of kernel messages, which reached back to about 31 seconds. What the kernel printed while starting is gone by then.
- **Crash reports** written during the start, such as the ones the untether leaves behind, because they are files.

From its first line on, every monitor runs while the boot record and the fourteen snapshots are written, which takes about a minute on a device that is still starting.

## The app

Finch Logs on the Home screen has five tabs. It runs on iPad and iPhone, upright or on its side.

- **Overview** shows whether the service is running, when the device started, what is running and in front, processor, memory, storage, network and battery right now, how big the store is, and how many lines each log has taken. What Has Run counts the apps, services and programs that have never run, and each count opens the list: apps, services or programs, either all of them, those that have run or those that never have, with a search field. A row shows the size of the thing, and its page everything the ledger holds for it. Everything Installed opens What Is Installed: the eight kinds with how many there are and the space they take, each opening a list that can be searched and put in order of size or name; the space on the system volume, with the files that belong to no kind by folder; and List Again, which asks the service for a fresh list. An item's page shows what it offers, what it is inside, whether it has been seen running, and what it needs and what needs it: the libraries it links, what it opens by name, the services it names, its entitlements, and what links, opens or names it, each a list that leads on to those items' own pages. Frameworks, bundles and libraries can also be put in order of Least Needed. Take Snapshots Now and Tidy the Store Now ask the service to do those at once.
- **Logs** lists every log. Tail Every Log follows all of them together, and opening one log shows its newest lines and follows it. Tail starts and stops following, Level hides lines below a level, the search field keeps only lines that contain what you type, and Files lists the log's hourly files, archived ones included. Touch a line to read all of it and copy it. Below the logs are the snapshots, and the dumps copied from the system with Import Log Dumps Now, which looks for new ones without waiting.
- **Processes** lists what is running with its processor use and memory, everything or apps only, sorted four ways.
- **Services** lists the services launchd knows, running, loaded or all, with a search field. A service's page shows its state, how it last ended, what starts it and its command.
- **Settings** changes how long logs are kept, how often the service looks, and which logs are recorded. Changes take effect at once.

## The command line

`finchlog` is also the tool for reading the logs from a shell, as root.

| Command                                             | What it does                                                                                                                                                                                           |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `finchlog status`                                   | Says how the service is doing                                                                                                                                                                          |
| `finchlog streams`                                  | Lists the logs, snapshots and dumps it keeps, with their sizes                                                                                                                                         |
| `finchlog tail [-n N] [-f] [--stream NAME]`         | Prints the newest lines, and with `-f` new ones as they come                                                                                                                                           |
| `finchlog read [--cursor C] [--lines N] [--follow]` | Prints lines after a cursor, for another program; FleetFinch Developer tails this                                                                                                                      |
| `finchlog files GROUP`                              | Lists the files of one log or snapshot                                                                                                                                                                 |
| `finchlog show FILE`                                | Prints one file, unpacked if it is archived                                                                                                                                                            |
| `finchlog dump [--hours H] [--gzip]`                | Writes every log as a tar archive to standard output                                                                                                                                                   |
| `finchlog collect [KIND]`                           | Gathers one kind of snapshot right now and prints it                                                                                                                                                   |
| `finchlog usage [--never]`                          | Prints what has run and what never has, and with `--never` only what never has                                                                                                                         |
| `finchlog inventory [KIND] [--fresh]`               | Prints everything installed, or one kind of it: `apps`, `extensions`, `services`, `xpc`, `frameworks`, `bundles`, `programs`, `libraries` or `storage`. With `--fresh` it lists everything again first |
| `finchlog depends [NAME] [--fresh]`                 | Prints what NAME links, opens by name and names, and what does the same to it. NAME is a path, an identifier, a label or a name. With no NAME it prints all of it                                      |
| `finchlog snapshot`, `import`, `maintain`, `reload` | Asks the service to do that now                                                                                                                                                                        |

## Reading the logs from a computer

FleetFinch Developer's Logs page has two options under Device for a device added over SSH:

- **Tail devices that run Finch Logs** shows every log as it is written. It keeps one connection open and sends nothing over it, so it does not wake a sleeping device: the lines stop while the device sleeps and carry on when it wakes. A silent device is looked in on after 2 minutes, then after 5, 10, 20 and 30, and every 30 minutes from then on, which is how a device that restarted is noticed. Each look wakes a sleeping device for about five seconds.
- **Import Log Dump…** copies the whole store to a file on the computer and shows the newest lines of each log and the newest snapshot of each kind.

## Building and installing

Set up the build tools once with Set Up Build Tools on FleetFinch Developer's Home page, which puts Theos, the toolchain and the iOS 9.3 SDK in `~/.fleetfinch/theos`. Then, from the repository root:

```sh
npm run build:logs
```

The package is `fleetfinch-logs/packages/com.fleetfinch.logs_1.0.0_iphoneos-arm.deb`. Install it from a device's page in FleetFinch Developer with Install App, or copy it to the device and run `dpkg -i` on it.

Removing the package stops the service and leaves the logs where they are. `dpkg --purge com.fleetfinch.logs` deletes them as well.

## Where the code is

| Folder    | What it holds                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `shared`  | What the service and the app both use: the store that writes and tidies the logs, the reader, the settings, the status files, the system readings, and the lookup of what needs what                                                                                                                                                                                                                                                                                                                           |
| `service` | The `finchlog` tool: `FLDaemon.m` runs the monitors on their schedules, each `FL…Monitor.m` feeds one or two logs, `FLProcessWatcher.m` waits for the kernel's process events, `FLCollect.m` takes the snapshots, `FLUsage.m` keeps the ledger of what has run and builds its report, `FLInventory.m` lists what is installed, `FLMachO.m` reads program files and the shared library cache, `FLDepends.m` works out what depends on what, `FLDump.m` writes the tar archive, and `main.m` is the command line |
| `app`     | The app: one view controller for each screen, built on the list in `FLListController.m`                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `layout`  | What the package adds besides the two programs: the launch daemon and the scripts that start and stop it                                                                                                                                                                                                                                                                                                                                                                                                       |

## What has and has not been tested

Everything above was run on an iPad 2 with iOS 9.3.5.

- **Restarts.** The iPad was restarted three times with `reboot` over SSH. Each time the service was running again without help, and wrote its first line 54 to 57 seconds after the start. From the second restart on it received its stop signal and saved what it knew. The third restart took two attempts: the first start died after about 20 seconds and the iPad restarted itself, which the service's copies of the system's own log files show.
- **Keeping and deleting.** Archiving after a day, adding to an archive of the same name, deleting after a week and the size limit were each run against files with made-up dates, with the real logs left as they were.
- **Sleep on battery.** Off its charger and locked, the iPad went to sleep six seconds after its screen turned off, and the service neither woke it nor kept it awake. With FleetFinch Developer's tail attached it slept through two and then five minutes of silence, woke for the tail's look each time and was asleep again five seconds later, and the tail's session outlived every sleep and carried on at the next wake. The kernel's record of each wake-up packet showed one fault, since fixed: the acknowledgement of a follower's last lines woke the iPad three seconds after it fell asleep, in 10 of 39 sleeps and up to three times running. Over those 39 sleeps and 20 more, a follower that keeps quiet while the device goes to sleep never woke it. Every one of those wakes has its kernel messages, its process changes and, when 30 seconds had passed, a resource sample, written within a tenth of a second of the wake. The longest sleep watched was five minutes; a night on battery was not.
- **Reading back.** `finchlog read` was asked for the 5,000 newest lines of the System Log, and for the 3,000 newest lines of every log together, and both answers were compared with the log files themselves: every line was there, in order, and none was skipped. Reading on from the cursor it gave returned only what was written afterwards. That comparison is how a fault was found and fixed: asked for thousands of lines, `finchlog tail -n` used to skip the first part of a large hourly file and carry on with older files.
- **What has run.** On the test iPad the report lists 76 apps, 389 services, with app extensions and XPC services among them, and 258 programs, and no item appears twice. Stopping and starting the service left every count as it was, and a ledger made to look as if the device had restarted counted each running process once more, as a restart should. An XPC service that the first version listed twice, under two names, is listed once. The new screens were captured on the iPad on its side and in the iPhone layout upright and on its side. What has not been done is the thing the ledger is for: a week or more of ordinary use.
- **Short runs.** 300 runs of `ls`, about eight milliseconds each, were all recorded with the device idle. With three busy loops running, 295 of 300 runs of `date` were named, 4 were noted as too short to name and 1 was missed. An earlier version put a short sleep in the thread that waits for the kernel and lost 17 of 300 idle runs, which is how it was found that the thread must never wait for anything else. Every SSH connection during the tests was recorded with its chain of `xpcproxy`, the `sshd-keygen-wrapper` script and `sshd`. A program that starts a copy of itself with other arguments, as the service does for its helper, was at first logged with its parent's command line; it now has its own, and 300 of 300 idle runs were still named afterwards.
- **What is installed.** The list was compared with a listing of every file on the system volume made with `find` and worked through on a computer. The 1,540 folders the service calls an app, an extension, an XPC service, a framework or a bundle were the same ones, of the same kinds and the same sizes, except that the service counts the block each symbolic link takes and `find` does not. Both counted 63,960 files and 28,902 folders, and the sizes of the kinds and folders added up exactly to the space the files take. Every definition marked as disabled or as not loaded on this model was missing from launchd's own list. Of the others, launchd had all but three: one is run once at boot and then forgotten, and why the other two were not loaded was not found. The walk took between 57 seconds and 1 minute 36 seconds, in a helper that held about 3 MB. The service listed everything again by itself after each new build was installed during the tests. On battery the iPad went to sleep five seconds after a listing began, the helper stopped with it, and the listing finished after the next wake. List Now in the app was pressed with no list present, and the list appeared when the helper finished.
- **What depends on what.** The helper read 657 programs, 968 libraries and 465 plug-ins. Its work was checked against three things it had no part in. A second reader, written in another language and run on a computer from a copy of each file's first block and of every library header in the shared cache, found the same links for all 2,090. `ldid` on the iPad printed the same entitlements for all 654 programs it was asked about, 4,487 keys in all. A second search of a copy of the shared cache found the same names in the 911 libraries it covered. For 150 things the helper said files on disk name, `grep` on the iPad found the name in the file every time: the thing's own path 115 times, its folder's 34 times and another name of the same library once. For 80 names the helper had not found in a file, `grep` found none either. The first comparison found two faults, both fixed: a file on disk was taken for the library of the same name in the shared cache, which the loader's own list of what `bash` loads settled, and a library's search paths did not include those of the program that loads it. Stopping the helper early, and again after the list was saved, made the service say so in each case and keep the list in the second. The whole takes the helper about two minutes and 36 seconds of processor.
- **The app's screens** were captured on the iPad upright and on its side, and in the iPhone layout by running an iPhone-only build on the iPad at 320 by 480 points. That showed list rows overlapping at iPhone width, which were reworked; afterwards the iPhone layout was captured upright only. The What Is Installed screens were captured on the iPad both ways and in the iPhone layout both ways, and the item pages with their lists on the iPad upright and in the iPhone layout both ways. Larger iPhone screens were not seen, and no iPhone was at hand.

These were not tested:

- **Switching the device off and on by hand.** Every restart was made over SSH.
- **A device with a passcode.** The store is made without data protection so that the service can write before the first unlock, but the test iPad has no passcode.
- **Another jailbreak.** When added daemons start, and how late, is the untether's doing. Only iocaste was tried.
- **Apps from the App Store.** The test iPad has none, so the walk of their folders found nothing to list.
- **A 64-bit device.** The reader of the shared library cache was written for 32-bit and 64-bit libraries and run only on a 32-bit device.

A process that lasts only a few milliseconds while the processor is saturated can exit before the service has read what it was. Such a run is noted in Processes as too short to name.

Kernel messages carry no numbers, so when the kernel prints exactly the same lines again and again the service cannot always tell how many times.

Finch Logs reads private parts of iOS that App Store apps may not use, so it works only on a jailbroken device.
