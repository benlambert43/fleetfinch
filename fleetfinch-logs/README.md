# Finch Logs

Finch Logs is a service and an app for jailbroken iOS 9 devices. The service starts with the device and keeps a detailed record of what the system, its services and its apps are doing. The app reads that record on the device, and FleetFinch Developer reads it from a computer.

It is written in Objective-C against the iOS 9.3 SDK and built with Theos for `armv7`, so it runs on every device that iOS 9.3.5 and 9.3.6 support.

## What it records

Each log is a folder of plain text files, one file for each hour.

| Log         | What goes in it                                                                                                                                                                                    | Where it comes from                                                                                    |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| System Log  | Every message the system log receives, from the kernel, services and apps, with its sender and level                                                                                               | The system log daemon's own socket, `/var/run/lockdown/syslog.sock`                                    |
| Kernel      | What the kernel prints while the service is running, and whatever its message buffer still held when the service started                                                                           | `proc_kmsgbuf`, read every 5 seconds                                                                   |
| Boot        | Each start of the device: when, how long it was off, how soon the service was recording, the kernel and its boot arguments, and every process already running, placed at the moment it began       | `sysctl`, the process table and launchd                                                                |
| Processes   | Every process that starts or exits, with its parent, user, command line and launchd service, the programs it passed through on the way, how long it ran, and the processor time and memory it used | Kernel process events for every fork, exec and exit, checked against the process table every 5 seconds |
| Apps        | Apps opening and closing, which app comes to the front, and apps being installed, updated or removed                                                                                               | The process table, SpringBoard and the app folders                                                     |
| Services    | Services added to or removed from launchd, started and stopped, with the exit code or signal each ended with                                                                                       | launchd's own job list                                                                                 |
| Resources   | Processor use for the device and each core, load, memory, free storage and disk traffic, network traffic and the battery; and the busiest and largest tasks                                        | Mach host statistics, `getmntinfo`, `getifaddrs` and IOKit, every 30 seconds                           |
| Power       | Sleep and wake with the reason for waking, charging, battery level, lock and display state                                                                                                         | IOKit power notifications and the battery driver                                                       |
| Network     | Interfaces, addresses and the Wi-Fi network as they change                                                                                                                                         | `getifaddrs`, CaptiveNetwork and the system's network change notifications                             |
| Connections | Each connection a process closed, with the server it was to, how long it lasted and the bytes each way                                                                                             | The kernel's own count for every socket, and the name lookups seen on Wi-Fi                            |
| Events      | 81 notifications the system posts about its own state, memory pressure, and changes to the clock or time zone                                                                                      | Darwin notifications                                                                                   |
| Log Files   | New lines in the log files other parts of the system write for themselves                                                                                                                          | `/var/mobile/Library/Logs`, `/Library/Logs`, `/var/log`, `/var/logs` and five more such folders        |
| Dumps       | A line for each crash report or other dump the system wrote, and a copy of the file itself when it is 8 MB or smaller; a dump the system only moves or renames is noted, not copied again          | The same folders                                                                                       |
| Changes     | Each part of iOS that was set aside, put back, moved off the system volume or deleted with `finchlog`, and each put-back the service made by itself                                                | The `finchlog` tool and the service                                                                    |
| Finch Logs  | What the service itself did: starting, snapshots, imports, tidying, and anything that failed                                                                                                       | The service                                                                                            |

A snapshot is a full picture of one part of the system at one moment. The service takes eighteen of them when the device starts and again each day, and the ones that change often every six hours: Environment, Device, Processes, Services, Apps, Packages, Storage Volumes, Network, Power and Battery, Kernel Messages, Kernel Extensions, Kernel Settings (every `sysctl` value), Hardware Registry (the whole I/O Registry), What Has Run (the report described under [What has run and what never has](#what-has-run-and-what-never-has)), and the four lists the service keeps itself: Problems per Component, Programs and Servers, Loaded Libraries and Changes. Seven more are written by helpers. What Is Installed and What Depends on What are taken once a day, after each start of the device and whenever something is installed or removed, as described under [What is installed](#what-is-installed) and [What depends on what](#what-depends-on-what). System Calls, Files Reached, Connections Between Programs, Files Read and What Looks Unused are taken once a day by the trace described under [What programs call and open](#what-programs-call-and-open).

## How the logs are kept

Everything is under `/var/mobile/Library/FinchLogs`.

| Path             | What it holds                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `live`           | The last day: `live/<log>/<date>_<hour>.log`, `live/snapshots/<kind>/<moment>.txt`, and copied dumps under `live/imports` |
| `archive`        | Older files, each compressed with gzip and kept under the same name and date                                              |
| `state`          | What the service knows between runs, and the status the app and the command line read                                     |
| `settings.plist` | Only the settings that differ from the defaults, written by the app                                                       |

One thing is kept outside that folder, so that removing Finch Logs cannot lose it: `/Library/FinchLogs` holds the record of the parts of iOS that were set aside and the parts themselves, as described under [Setting a part of iOS aside](#setting-a-part-of-ios-aside).

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

On an iPad 2 it uses about 0.5% of one processor core while the device is awake, 1% while the app is open, and nothing while the device sleeps: it does not keep the device awake. Recording a process that starts and exits costs it about 3.6 milliseconds of processor. It holds about 3 MB of memory. Listing what is installed, and working out what depends on what, is done by a helper, which uses about 36 seconds of processor each time.

## How processes are followed

The service asks the kernel to tell it whenever any process forks, runs a new program or exits, and one thread does nothing but wait for that, at a fixed priority above ordinary programs so that it is not kept waiting when the device is busy. The moment a process forks, the thread finds the new child, starts following it too, and reads what it is. A command that lasts eight milliseconds is recorded with its real start, its command line and how long it ran.

- **A start line is written once the process has settled.** A new process often runs one or two programs on the way to its own: launchd starts every service through `xpcproxy`, and `sshd` through a script as well. The line names the last program and the ones before it, as in "started pid 3342 by launchd (pid 1) for com.openssh.sshd… by way of xpcproxy and sshd-keygen-wrapper". A process that changes program later gets a line of its own, "now runs".
- **A copy that never runs a program of its own is left out.** A shell forks a copy of itself for every command, and the copy is recorded only once it runs the command, or if it is still there after a second.
- **Lines carry the real times.** A start line is stamped with the moment the program began and an exit line with the moment it ended, to the millisecond, whenever the service gets round to writing them.
- **Processor time at exit** is read from the kernel when it still has it, which is about half the time for a short run. Memory is known only for a process that lived long enough to be sampled.
- **The process table is still compared** every five seconds, as a check on the events and for whatever was running before the service started.

Services are still found by comparing launchd's list, which is read again whenever launchd starts or loses a process. One that starts and stops between two readings is in Processes, with its name, and counted under What Has Run, but may be missing from Services.

launchd is also asked about each service by name, the way `launchctl print` asks on a Mac. It answers with how often it has run the service since the device started, whether it is running, and the reason it gave for the last start. The service asks about all of them 20 seconds after it starts, which takes about two seconds of processor for 270 services, and about one of them a second after it sees that one start. This is launchd's own count, so it covers what ran and ended before Finch Logs was running. The reasons launchd gave on the test iPad:

| launchd's word   | What it means                                                                            |
| ---------------- | ---------------------------------------------------------------------------------------- |
| `ipc (mach)`     | A program asked for a Mach service the service offers                                    |
| `ipc (socket)`   | A connection came in on a socket launchd holds for it                                    |
| `xpc event`      | An event it had asked to be started for: a notification, a piece of hardware, a set time |
| `semaphore`      | A condition it is kept running under held, such as a file being there                    |
| `speculative`    | launchd started it without being asked, as it does for a service marked to run at boot   |
| `system support` | launchd needs it for itself                                                              |

launchd gives the reason only while the service is running, so one that started and ended before it was asked has a count and no reason.

iOS treats a launch daemon it has no rules for as idle: launchd may kill it without warning, and the kernel kills it if it uses more than 5 MB of memory. The service therefore tells launchd that it is always busy, which gets it a stop signal and time to save what it knows, and raises its own allowance to 16 MB. It stays far below that: the most it has been seen to hold is 3.1 MB.

## When the device sleeps

A locked iPad on battery goes to sleep about five seconds after it last woke, and the service's clocks stop with it: nothing is sampled and nothing is written until it wakes. The service does not keep the device awake and never wakes it.

Each sleep and each wake is a line in Power, with how long the device slept and what woke it. On waking, the service at once reads the kernel's messages and the process table, takes a resource sample, battery included, if the last one is more than 30 seconds old, and brings its status up to date, so a wake of a few seconds is recorded in full. Kernel messages carry no time of their own and are stamped when they are read, so what the kernel printed while going to sleep is stamped at the next wake. Going to sleep and waking make the kernel print about as much as its 4 KB buffer holds, so now and then the Kernel log loses the first lines of that and says so. The System Log has the same messages, all of them, with the system's own times.

Any packet sent to the device over Wi-Fi wakes it: a new connection, a keep-alive probe on an open SSH session, even the acknowledgement of something the device sent. The kernel prints the packet that woke it, which both the Kernel log and the System Log keep. `finchlog read --follow` and `finchlog tail -f` therefore print nothing from the moment the device starts going to sleep until it wakes: the acknowledgement of a line sent in that moment would reach the device after it slept and wake it again.

## What has run and what never has

The logs are deleted after a week, so the service also keeps a ledger that is never deleted: one record for each program, each launchd service and each app it has seen running. A record holds when it was first and last seen, how many runs were seen, how long it ran, the processor time it used, the most memory it held, what started it and, for a service, how it ended, how often launchd says it has run it and why. For an app it also holds how often it was in front, for how long, and when it last was. The ledger is `state/usage.plist` in the store. It is saved at most every five minutes and whenever the service stops, and deleting it while the service is stopped starts the count again.

- **An app** is counted by its bundle identifier, **a service** by its launchd label and **a program** by the path of its executable. Labels that launchd makes afresh for each use, such as one `sshd` for every connection, are counted as one.
- A process counts for its program and for the service or app it runs as. A program is listed only when it has run outside any service or app, so a daemon appears once, under Services.
- **In front** means the app was the one on the screen while the device was not locked, which the service looks at every five seconds. iOS starts some apps by itself where nobody sees them, Mail and Safari on the test iPad after every start, so the report lists the apps that have been in front, the ones that ran without ever being in front, and the ones that never ran.
- **Started by launchd** is launchd's own count for a service, described under [How processes are followed](#how-processes-are-followed). A service that launchd has run counts as having run, even when Finch Logs never saw its process: 22 services on the test iPad had run and ended seven minutes after a start, most of them in its first minute. When the ledger is new, only a run still in progress is taken from launchd's count for the start it began in, so that nothing from before the ledger is counted.
- **File read** is shown for whatever never ran: the last time the file of its program was read, when that was since the count described under [What has been read](#what-has-been-read) began. Running a program reads its file, so this is how a program that is not a launch service shows up when it ran before Finch Logs was running.
- **Never ran** is whatever is installed and has no runs and no starts by launchd. What is installed comes from the list described under [What is installed](#what-is-installed): every app in `/Applications` and the app containers, every app extension and XPC service, and every program on the system volume. Services come from launchd: every one defined in its folders or known to it. App extensions and XPC services are listed with the services.
- **From** names the dpkg package that installed it. Whatever dpkg did not install is counted as part of iOS.
- **Size** is the space the thing takes on the volume, and for a service the space its program takes.
- A service that launchd does not load on this model of device says so.

The report says first how long the ledger has been counting, how much of that time the device was awake, and over how many starts of the device, because "never ran" means only that much. What the ledger cannot see:

- A run of a few milliseconds can end before it is named when the processor is saturated. It is then counted as "(too short to name)", with what started it, so the count shows how much is being missed. With the device idle, 300 of 300 eight-millisecond runs were named; with three busy loops on its two cores, 295 of 300, with 4 counted as too short to name and 1 missed.
- A script counts under its own path, as well as its interpreter's, when it is started by its `#!` line with a full path. A script handed to an interpreter by hand, as in `sh thing.sh`, counts as the interpreter only.
- Frameworks, plug-ins and libraries are not listed, because they are loaded into other programs and never run by themselves. [What depends on what](#what-depends-on-what) sorts them by whether anything that has run needs them.
- Until the service has listed what is installed, which it does within a few minutes of being installed, apps, extensions and programs that have never run are missing, and the report says so.
- Nothing is counted while the device sleeps. In a start, before the service is running, a process that is still running later is counted from the moment it began, a launch service is counted by launchd, and any other program shows only by its file having been read, which leaves no trace in the first 20 seconds or so, as described under [What it sees of a restart](#what-it-sees-of-a-restart).

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

Every item also has its size, its path, what it is nested inside, where it came from (the dpkg package that installed it, or iOS), and how many of its files have been read and when the last was, as described under [What has been read](#what-has-been-read).

- **A size is the space a thing takes on the volume**, which is what removing it would free. iOS keeps many files compressed, so this is often less than their length. A file that compresses to under 4 KB is kept inside the file system's own records and takes no space of its own, so a thing made only of such files shows as 0 bytes. The size of a folder includes what is nested inside it.
- **The whole volume is accounted for.** Files that belong to none of the eight kinds, such as fonts, sounds and language data, are added up by folder. The sizes of the kinds and of those folders add up to the space all the files take.
- **The shared library cache** is one file that holds most of the system's libraries. The list says which frameworks keep their library there and how much of the cache each takes. Such a library takes no space of its own and cannot be removed by itself, so removing a framework's folder frees only its other files.
- **Launch services are described from their definitions.** One whose `LimitLoadToHardware` or `LimitLoadFromHardware` key rules out this model of device is marked as not loaded on this model. One switched off in its file or in launchd's own record, `/var/db/com.apple.xpc.launchd/disabled.plist`, is marked as disabled. Whether launchd has a definition loaded at this moment is in the Services snapshot.

The walk reads about 64,000 files, and with the reading described under [What depends on what](#what-depends-on-what) it takes about two minutes on an iPad 2, so the service does not do it itself. It starts `finchlog inventory --save` as a helper at low priority and carries on recording, and a fault in the helper cannot stop the service. A minute after it starts, and every ten minutes from then on, the service starts the helper if nothing is listed yet, if the device has started since the last list, if the list is a day old, or if something was installed or removed, which it notices by the dates of the dpkg record, the launchd folders, `/Applications` and the other folders that programs live in. Only one listing runs at a time, and only root can ask for one, because a listing reads every program and has to put each file's time of last reading back afterwards. The helper does not keep the device awake: on battery it stops when the device sleeps and carries on at the next wake.

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

1. **Loaded by a program that has run.** Links alone lead to it from a program in the ledger, or from one whose file has been read since [the count of what is read](#what-has-been-read) began.
2. **May be opened by a program that has run.** The way to it from such a program goes through something opened by name.
3. **Needed only by programs that have never run.**
4. **Needed only by plug-ins that nothing names.**
5. **A plug-in that nothing names.** No program has its path, or its folder's, among its strings.
6. **Nothing found that needs it.**

Two more groups come from watching rather than reading, and sit between the first and the second: **seen loaded in a running program**, described under [What running programs really load](#what-running-programs-really-load), and **its file has been read**, for a library or plug-in on disk whose own file was read since the count began, which is what loading it does.

The groups are worked out when the list is made, from the ledger as it stood then, so they are a day old at most. `finchlog depends NAME` prints one item: what it links, opens and names, what links, opens and names it, its entitlements and its group. In the app the same is on the item's page under What Is Installed.

**Needed by Nothing Else** answers the question that comes with removing something: what else could go with it. For an app, a framework, a bundle or a launch service it lists the frameworks, bundles, libraries and programs that are reached only from it, by links or by names, and from no other program or plug-in that was found, and that no other program was seen to load. Removing iBooks on the test iPad would leave `TSReading.framework`, 3.6 MB, with nothing that needs it, and setting the `com.apple.gamed` launch service aside would leave its program, `gamed`. Every program and every plug-in outside the thing counts as a reason to keep what it reaches, whether or not it ever runs, so the list errs towards being short.

- **The shared cache comes first, as it does for the loader.** A file on disk with the name of a library in the cache is never loaded. On the test iPad that is Cydia's `/usr/lib/libncurses.5.dylib`: `bash` links that name and gets the copy in the cache.
- **A link to a library that is not on the device is reported.** Seven programs and plug-ins on the test iPad cannot load for that reason, five of them app extensions that link `RadarCompose`, a framework that is not on the device.
- **The launch services, XPC services and apps** are each listed with the programs and libraries that name them.

What it cannot see:

- **A name the program puts together while it runs.** The keyboard's layouts, `KBLayouts_iPad.dylib`, 20 MB of the shared cache, are in the last group because TextInput makes the name from `KBLayouts_%@.dylib`. The last three groups are where to look, not a list of what is safe to remove.
- **Whether a name that is there is ever used.** A program that names a service may never call it.
- **Which plug-ins a program really loads.** Naming a folder of plug-ins counts as opening every plug-in in it.
- **Scripts.** What a shell script runs is not read.

## How each component is doing

The ledger of what has run also counts trouble for each app, service and program:

- **Reports** the system wrote about it: crash reports, low memory reports, and launchd's own reports. The first line of each dump names the program, and its `Path:` line says where the program is, so a report is counted for the program, for the service that runs it and for the app it is inside.
- **Bad endings**: each time a service stopped with a signal or an exit code other than 0.
- **Faults and errors**: each message it wrote to the system log at those two levels, matched to what was running by its process number, and by name when that process is gone.

`finchlog health`, and Problems in the app, list the components in four groups: those that had reports written about them, those that ended badly, those that logged faults, and those that logged errors only. Each row leads to the counts and to the component's own page. A count is only ever a number of events: it says a component is unhealthy, not why.

## Which programs talk to which servers

The kernel keeps a count for every socket, and tells the service of each one as it opens and closes: the process, the program's name, both addresses, and the bytes each way. When a connection closes, the service writes a line to the Connections log and adds it to a ledger, `state/traffic.plist`, under the program and the server.

A server is shown by name when the name was looked up while the service was watching: it reads the answers to name lookups from Wi-Fi, and nothing else from the network. Names that were looked up and do not exist are listed too, since a service that keeps asking for a server that is gone is one the system no longer needs; the answer does not say which program asked. A connection `mDNSResponder` or another helper makes for a program is shown with the program it was for.

`finchlog connections`, and Servers in the app, list the programs that have talked over the network with each server and its bytes, the servers with the programs that use them, the programs that wait for connections and on which ports, and the connections open now.

A connection is counted when it closes, so one that stays open for days is listed under Connections Open Now until it does. A connection that arrives through a socket launchd holds, and closes within a second, can be listed under launchd, because the program it was handed to is gone before the kernel can name it.

## What running programs really load

Reading program files shows what a program links, and the names it holds, but not what it opens by a name it puts together while it runs. So every five minutes while the device is awake, and 2 and 20 seconds after each new process starts, the service reads each running process's own list of the code it has loaded, and records for every library and plug-in which programs had it loaded and when (`state/loaded.plist`).

On the test iPad the first look read 122 programs and found 68 libraries and plug-ins loaded from files of their own and 573 from the shared library cache. Among the first were all 28 plug-ins of `UserEventAgent`, the sync bundles of `atc`, and the network bundles of `configd`, none of which any program names whole.

This gives the groups described under [What depends on what](#what-depends-on-what) one more, between the first and the second: **seen loaded in a running program**. On the test iPad 124 libraries and plug-ins moved into it from the weaker groups. A library's page lists Seen Loaded By, and a program's page lists Seen Loading From Files of Their Own. `finchlog loaded` prints the whole record, as Loaded Libraries does in the app.

What a program loads and lets go of between two looks is missed, and so is everything loaded by a program that runs for less than two seconds.

## What has been read

The file system keeps, for every file, the time it was last read. iOS never uses it, because it keeps the system volume read-only, but a jailbreak makes that volume writable and from then on the times move. They cover every file, all of the time, and cost nothing while the device runs, which makes them the widest evidence there is of what is in use.

What moves the time was measured on the test iPad, on files nothing had read since iOS was installed:

| What was done to the file                                 | Did the time move |
| --------------------------------------------------------- | ----------------- |
| Reading it                                                | Yes               |
| Mapping it into memory and touching its pages             | Yes               |
| Running it as a program                                   | Yes               |
| Opening it without reading                                | No                |
| Asking for its attributes, or listing the folder it is in | No                |

Reading and mapping were tried on all three ways iOS stores a file: plain, compressed inside the file system's own records, and compressed in its resource fork.

- **The count begins when Finch Logs first lists what is installed** with this in it, and `state/touched.plist` holds that moment. A file counts as read when its time is at or after it. Deleting that file while the service is stopped starts the count again.
- **Finch Logs puts the time back after its own reading.** Listing what is installed reads the head of every program and library, every bundle's `Info.plist` and every launch definition, about 3,100 files. Each file's time of last reading is set back to what it was, which moves the file's time of last change instead. After a listing on the test iPad, 3 of 63,771 files had a time inside the two minutes it took: `sleep` and `xpcproxy`, which really ran then, and the shared library cache, which has since been fixed.
- **The listing collects the times as it walks the volume**, so they are as fresh as the list: after each start, once a day, and whenever `finchlog touched --fresh` or List Again asks. Each app, extension, XPC service, framework and bundle gets how many of its files were read and when the last was. The files that only describe a bundle (`Info.plist`, `InfoPlist.strings`, `PkgInfo` and its code signature's list) are counted apart, because the system reads those when it lists what is installed, whether or not anything uses the bundle.
- **What the device reads while starting is recorded for each start.** When a listing begins within fifteen minutes of a start, every file read since the start is added to `state/startup.plist` with the number of starts it was read in. On the test iPad that listing begins about two minutes after the start and finds about 700 files.

`finchlog touched`, and Files Read in the app, show:

- **Installed things nothing has read**, largest first, and the folders of other files, the single programs and libraries, and the largest single files, in the same way.
- **Translations, by language**: every `.lproj` folder on the system volume added up by language, with how many of its files were read.
- **Read while the device was starting**, by the thing or folder the files are in.
- **Installed things and folders that were read from**, the latest first.

`finchlog touched PATH` lists each file under PATH with its time, and `finchlog touched --starting` each file read while starting.

On the test iPad, a day and a half after its jailbreak and after six restarts, 59,305 of the 63,773 files on the system volume, 903 MB of 1.7 GB, still carried a time from before the volume was made: nothing had read them since iOS was installed.

What it cannot show:

- **The first part of a start.** iOS keeps the system volume read-only until the jailbreak has made it writable, 21 to 23 seconds after the start on the test iPad, and nothing read before then leaves a trace. What launchd started in that time it counts itself, as described under [How processes are followed](#how-processes-are-followed).
- **A file a program already holds.** A program that read or mapped a file before the count began does not read it again, so what long-running services use shows once the device has restarted since the count began.
- **Who read it.** The time says that a file was read and when, not by what. The trace described next says by what, for the time it runs.
- **Reading by something that reads everything.** A search of the whole volume, a backup with `tar`, or an older Finch Logs, which did not put the times back, makes everything look read. A time from before the count began is shown as it stands, and for a program or a library it may be an older Finch Logs' own doing.
- **The data volume**, which iOS mounts so that these times are not kept.
- **Libraries inside the shared library cache.** They are not files. [What running programs really load](#what-running-programs-really-load) covers them.

## What programs call and open

`finchlog trace` switches on the kernel's own trace for a while and reads four things from it for every program: each system call it makes and whether it failed, each kernel trap, each path it looks up, and each thread and process that starts. The service runs a trace of 20 seconds every 30 minutes while the device is awake, which Settings can change or switch off, and `finchlog trace --for SECONDS` runs one of any length up to six hours, which is the way to record a spell of ordinary use. With `--name PROGRAM` it also prints everything that one program did: every call with its count, and every path it opened or looked at.

Each trace is added to a record, `state/trace.plist`, and four lists are made from it:

- **System Calls** (`finchlog calls`): for each program, the calls it made with how often each failed and with what error; for each call, the programs that made it; the calls the kernel refused as not supported, which is a program still asking for something this kernel does not do; and the system calls nothing made at all.
- **Files Reached** (`finchlog opened`): every path a program reached is counted under the installed thing it is inside, or under its folder when it is inside none, as opened when an open or a start worked and as looked at when the path was only checked. The last group is the apps, frameworks, bundles and programs in which no traced program reached a file, largest first.
- **Connections Between Programs** (`finchlog talks`): at the end of each trace the service reads every process's table of ports. A program that holds the right to send to a port another program receives on has a connection to it, so the list shows, for each service, who would notice if it were gone.
- **What Looks Unused** (`finchlog candidates`): everything above and [what has been read](#what-has-been-read), put together. An app is listed when it never ran and nothing inside it was run or loaded, and apart from those, when iOS started it but it was never in front; a launch service when neither Finch Logs nor launchd saw it start and the file of its program was not read; a program when it never ran and its file was not read; a framework, bundle or library when nothing that has run needs it, it was never seen loaded, none of its files was read and the device read nothing in it while starting; a bundle that holds no program when none of its files was read; a folder of other files in the same way; and a language when none of its files was read anywhere on the volume. Each list is in order of size, with its total, and a row says what little was seen of the thing, such as that only the files that describe it were read. Nothing a package installed is listed, and nothing the device needs to start, to be reached or to undo a change.

What these can and cannot show:

- A trace sees the calls that cross into the kernel. What a program calls inside its own libraries cannot be seen from outside it.
- This kernel writes no record for each message one process sends another, so Connections Between Programs shows who was connected when the service looked, not each message.
- The kernel's record keeps the last 92 characters of a path. A longer one can only be placed when a folder in it has a name no other installed thing has. A path that passes through a symbolic link other than `/var`, `/etc` and `/tmp` is recorded from the link onwards, and is counted apart as one that could not be placed.
- Tracing is one facility the whole system shares, so only one trace runs at a time, and the service does not start its own while the helper that lists what is installed is reading the volume.
- What Looks Unused is evidence, not proof. It means more the longer the device has been in ordinary use, and a thing used once a month looks the same as one never used until that month has passed. A program that runs only before the system volume is writable, in the first 20 seconds or so of a start, and that launchd does not start, is seen by nothing and is listed although the start may need it; the untether's own use of `racoon` is one, and is why what the untether needs is never set aside.

## Setting a part of iOS aside

`finchlog hold NAME` moves an app, a framework, a bundle, a program or a launch service's definition to `/Library/FinchLogs/Held/<number>/`, where iOS no longer finds it. NAME is a path, a launch service's label or a name. The move is within the system volume, so it is instant, exact and undone by moving it back. A launch service is unloaded from launchd first, which stops it, and loaded again when it is put back. Each change gets a number, a line in the Changes log and an entry in `/Library/FinchLogs/changes.plist`.

| Command                            | What it does                                                                                                                                              |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `finchlog hold NAME --check`       | Only says whether NAME would be set aside and what stands in the way, how many of its files have been read, and what nothing else would need with it gone |
| `finchlog hold NAME [--note TEXT]` | Sets NAME aside                                                                                                                                           |
| `finchlog restore NUMBER`          | Puts it back where it was                                                                                                                                 |
| `finchlog store NUMBER`            | Copies it to `/private/var/FinchLogsHeld` on the data volume, checks the copy byte for byte, and deletes it from the system volume to free the space      |
| `finchlog discard NUMBER --yes`    | Deletes it for good                                                                                                                                       |
| `finchlog changes`                 | Lists every change, and for each one still in force, what differs since it was made                                                                       |

Some things are never set aside, whatever is asked: `launchd`, `dyld`, the shared library cache, SpringBoard, everything in `/etc` and on the data volume, what the iocaste untether needs at start-up (`racoon`, `dhcpd`, `wifiFirmwareLoader` and their settings), `wifid` and `configd` with its bundles, anything those programs, `sshd`, the shell or Finch Logs link or were seen loading, anything a package installed, and a plain folder that holds several installed things. Others need `--force`: a program that is running, a library linked by something that has run, anything seen loaded in a running program, and anything the device read while starting, except an app of which it read no program. After setting a thing aside the tool lists what nothing else would need now, as [Needed by Nothing Else](#what-depends-on-what) does.

Before each change the tool keeps the counts of everything in the ledger. `finchlog changes`, and Changes in the app, then show for each change what differs since: a component that has not run although it ran often enough before to be expected, one that ran for the first time, and new reports, bad endings, faults and errors beyond what the time since would explain. Each line is something that differs, not proof that the change caused it.

A change that has not yet been through a restart is on trial. Two minutes after it starts again, the service checks that SpringBoard is running, that the device answers on its SSH port and that it has a network address, each only if it was so before the change. If all is well the change is marked as through a restart. If something is missing the service keeps checking for at least four minutes more, so that a slow start is not taken for a broken one, and then puts back every change that is on trial, newest first, loads the services again, and says so in the Changes log. After a real restart that took eight minutes from the moment the service started, because it is busy then. A change's page in the app has a Put It Back button, for when the device can be used but not reached.

The guards were written for iOS 9.3.5 with the iocaste untether, from what that untether was seen to use. Another jailbreak needs other names. The automatic put-back depends on the service starting, which depends on the jailbreak, so it cannot help if a change stops the jailbreak itself; that is what the list of things never set aside is for. Setting an app aside leaves its icon on the Home screen until `uicache` is run or the device restarts.

## What it sees of a restart

Nothing that is not part of iOS runs until the jailbreak has done its work, so the service misses the first part of every start. On the test iPad, which uses the iocaste untether:

| After the device starts | What happens                                                                                                            |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 3.5 seconds             | launchd starts the first system services, the system log among them                                                     |
| 21 to 23 seconds        | The jailbreak makes the system volume writable, and from then on reading a file leaves its time                         |
| 31 seconds              | The jailbreak is in place, and launchd starts SpringBoard, Finch Logs and the other added daemons                       |
| 47 to 57 seconds        | The added programs begin to run, Cydia's start-up script as late as the service, which writes its first line            |
| About 2 minutes         | The service lists what is installed, and with it every file read since the start, which takes about a minute and a half |

What the service has from before its first line:

- **Processes.** Every process still running, with the moment it began, back to launchd itself. A process that started and exited before the first line is not there.
- **System log.** The last 250 or so messages, which is all the system log keeps. They reached back to about 33 seconds after the start.
- **Kernel.** The last 4 KB of kernel messages, which reached back to about 31 seconds. What the kernel printed while starting is gone by then.
- **Crash reports** written during the start, such as the ones the untether leaves behind, because they are files.
- **Launch services.** launchd's own count of how often it has run each one since the start, as described under [How processes are followed](#how-processes-are-followed). After one start on the test iPad it had run 125 of its 270 services, and 22 of those had already ended.
- **Files.** Every file read from the moment the system volume was writable, as described under [What has been read](#what-has-been-read): about 590 in the twenty seconds after it, among them app extensions and Cydia's start-up tools that ran and ended before the first line.

What nothing has is a program that is not a launch service and ran only in the first 20 seconds or so.

From its first line on, every monitor runs while the boot record and the fourteen snapshots are written, which takes about a minute on a device that is still starting.

## The app

Finch Logs on the Home screen has five tabs. It runs on iPad and iPhone, upright or on its side.

- **Overview** shows whether the service is running, when the device started, what is running and in front, processor, memory, storage, network and battery right now, how big the store is, and how many lines each log has taken. What Has Run counts the apps, services and programs that have never run, and the apps that have been in front, and each count opens the list: apps, services or programs, either all of them, those that have run or those that never have, with a search field. A row shows the size of the thing, how often an app was in front, and when the file of a thing that never ran was read; its page shows everything the ledger holds for it, launchd's count and reason among it. Everything Installed opens What Is Installed: the eight kinds with how many there are and the space they take, each opening a list that can be searched and put in order of size or name; the space on the system volume, with the files that belong to no kind by folder; and List Again, which asks the service for a fresh list. An item's page shows what it offers, what it is inside, whether it has been seen running, how many of its files have been read, when the last was and how many the device read while starting, and what it needs and what needs it: the libraries it links, what it opens by name, the services it names, its entitlements, what links, opens or names it, and what nothing else would need if it were gone, each a list that leads on to those items' own pages. Frameworks, bundles and libraries can also be put in order of Least Needed. Take Snapshots Now and Tidy the Store Now ask the service to do those at once. What Was Observed opens nine lists: What Looks Unused, Files Read, Problems, Servers, Loaded Libraries, Files Reached, Connections Between Programs, System Calls and Changes. Each shows its groups with how many are in each, a group opens a list with a search field, and a row opens a page with everything known about it and a way to its page in What Is Installed. A change that is still in force has a Put It Back button there.
- **Logs** lists every log. Tail Every Log follows all of them together, and opening one log shows its newest lines and follows it. Tail starts and stops following, Level hides lines below a level, the search field keeps only lines that contain what you type, and Files lists the log's hourly files, archived ones included. Touch a line to read all of it and copy it. Below the logs are the snapshots, and the dumps copied from the system with Import Log Dumps Now, which looks for new ones without waiting.
- **Processes** lists what is running with its processor use and memory, everything or apps only, sorted four ways.
- **Services** lists the services launchd knows, running, loaded or all, with a search field. A service's page shows its state, how it last ended, what starts it and its command.
- **Settings** changes how long logs are kept, how often the service looks and how often it traces, and which logs are recorded. Changes take effect at once.

## The command line

`finchlog` is also the tool for reading the logs from a shell, as root.

| Command                                                   | What it does                                                                                                                                                                                                                     |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `finchlog status`                                         | Says how the service is doing                                                                                                                                                                                                    |
| `finchlog streams`                                        | Lists the logs, snapshots and dumps it keeps, with their sizes                                                                                                                                                                   |
| `finchlog tail [-n N] [-f] [--stream NAME]`               | Prints the newest lines, and with `-f` new ones as they come                                                                                                                                                                     |
| `finchlog read [--cursor C] [--lines N] [--follow]`       | Prints lines after a cursor, for another program; FleetFinch Developer tails this                                                                                                                                                |
| `finchlog files GROUP`                                    | Lists the files of one log or snapshot                                                                                                                                                                                           |
| `finchlog show FILE`                                      | Prints one file, unpacked if it is archived                                                                                                                                                                                      |
| `finchlog dump [--hours H] [--gzip]`                      | Writes every log as a tar archive to standard output                                                                                                                                                                             |
| `finchlog collect [KIND]`                                 | Gathers one kind of snapshot right now and prints it                                                                                                                                                                             |
| `finchlog usage [--never]`                                | Prints what has run and what never has, and with `--never` only what never has                                                                                                                                                   |
| `finchlog inventory [KIND] [--fresh]`                     | Prints everything installed, or one kind of it: `apps`, `extensions`, `services`, `xpc`, `frameworks`, `bundles`, `programs`, `libraries` or `storage`. With `--fresh` it lists everything again first                           |
| `finchlog depends [NAME] [--fresh]`                       | Prints what NAME links, opens by name and names, and what does the same to it. NAME is a path, an identifier, a label or a name. With no NAME it prints all of it                                                                |
| `finchlog health`                                         | Prints the reports, bad endings, faults and errors of each component                                                                                                                                                             |
| `finchlog connections`                                    | Prints which programs talk to which servers, and which wait for connections                                                                                                                                                      |
| `finchlog loaded`                                         | Prints the libraries and plug-ins running programs have really loaded                                                                                                                                                            |
| `finchlog trace [--for S] [--name PROGRAM]`               | Records every system call, kernel trap and file lookup for S seconds, 20 unless told, and with `--name` prints everything one program did                                                                                        |
| `finchlog calls`, `opened`, `talks`                       | Print what the traces have gathered: the calls each program makes, which parts of the system had files opened, and who holds connections to whom                                                                                 |
| `finchlog touched [PATH] [--fresh] [--starting]`          | Prints what has been read since the count began and what never has. With PATH it lists each file under it, with `--starting` each file the device read while starting, and with `--fresh` it lists what is installed again first |
| `finchlog candidates`                                     | Prints what nothing recorded so far has used, in order of size                                                                                                                                                                   |
| `finchlog hold`, `restore`, `store`, `discard`, `changes` | Set a part of iOS aside and put it back, as described under [Setting a part of iOS aside](#setting-a-part-of-ios-aside)                                                                                                          |
| `finchlog snapshot`, `import`, `maintain`, `reload`       | Asks the service to do that now                                                                                                                                                                                                  |

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

| Folder    | What it holds                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `shared`  | What the service and the app both use: the store that writes and tidies the logs, the reader, the settings, the status files, the system readings, the lookup of what needs what, the shape every list of findings has (`FLReport.m`), and the reader of the record of loaded libraries                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `service` | The `finchlog` tool: `FLDaemon.m` runs the monitors on their schedules, each `FL…Monitor.m` feeds one or two logs, `FLProcessWatcher.m` waits for the kernel's process events, `FLCollect.m` takes the snapshots, `FLUsage.m` keeps the ledger of what has run and builds its report, `FLInventory.m` lists what is installed, `FLMachO.m` reads program files and the shared library cache, `FLDepends.m` works out what depends on what, `FLDump.m` writes the tar archive, and `main.m` is the command line. `FLTrafficMonitor.m` follows connections and `FLLoadedMonitor.m` loaded libraries; `FLTrace.m` runs the kernel trace and makes its lists, with the names of the calls in `FLCallNames.m` and the reader of port tables in `FLPorts.m`; `FLReports.m` builds the lists the service keeps itself, `FLTouched.m` the list of what has been read, `FLCandidates.m` the list of what looks unused, `FLLaunchd.m` asks launchd about a service, and `FLChanges.m` sets parts of iOS aside and puts them back |
| `app`     | The app: one view controller for each screen, built on the list in `FLListController.m`. `FLReportController.m` shows any of the lists of findings                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `layout`  | What the package adds besides the two programs: the launch daemon and the scripts that start and stop it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

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
- **How each component is doing.** A copy of a real crash report and of a real launchd report were put where the system writes them: the first was counted for the extension it named, found by its path, and the second for its service. Errors in the system log were counted for the services that wrote them. The copies were deleted afterwards.
- **Servers.** A page fetched with the shell was recorded with its server by name and the bytes each way; the lookup `mDNSResponder` made for it was shown as made for the shell; a name that does not exist was listed; and the listening ports matched `launchd`'s and `lockdownd`'s sockets. Connections that arrive through a launchd socket were first shown with the caller's own port, which was fixed.
- **A restart with changes in force.** The iPad was restarted once more with two test changes set aside: a launch service that the service was made to judge unreachable, by a build that looks for the wrong SSH port, and a folder. launchd did not start the service that was set aside. The service was running 57 seconds after the start and took its 18 snapshots, ran its trace and read 199,622 records without losing one. Eight minutes after it started it marked the folder as through a restart, put the launch service back by itself and loaded it, and the service's program was running again. The wrong port is the one part of this that was arranged: nothing was broken for real.
- **Loaded libraries.** The first look read 122 running programs, none refused. A bundle the list of what is installed had described without its program, because its `Info.plist` names none, turned up as loaded; such bundles now take their folder's name, as iOS does.
- **Tracing.** One trace read 38,457 records from 104 programs in 8 seconds and lost none, and all 117 port tables were read. The service ran its own 20-second trace on time and wrote its lists and snapshots. A second trace was refused while one ran, an interrupted trace switched the kernel's trace off and kept what it had, and after a trace was killed the next one took the kernel's trace over. Traced on its own, `sshd` was shown opening its settings, its host keys and the account's authorized keys, which is what it does. The counts were not checked against a second tracer, because the device has none.
- **Setting aside.** Every part of it was run on a folder and a launch service made for the purpose: set aside, moved to the data volume and put back with every file, owner, mode and time the same; the service unloaded and loaded again; deleted for good only with `--yes`; and put back from the app's button. The automatic put-back was run with a build made to look for the wrong port, which put both changes back by itself and loaded the service again, and the unchanged build marked two changes as through a restart. Forty-eight names that must be refused were tried with `--check` on the final build, and all were, as seven that should be allowed were allowed. One fault was found the hard way: an early version did not notice that a program was running, and `mDNSResponder`'s own file sat set aside for 25 seconds before it was put back, unchanged, with the process still running.
- **What has been read.** Twelve small experiments on files nothing had read since iOS was installed gave the table under [What has been read](#what-has-been-read), and the files were given their old times back. Whether a listing leaves a trace was checked by listing every file's times with `find` before and after one: of 63,771 files, three had a time inside the listing's two minutes, two of them programs that really ran, and the third, the shared library cache, was then fixed. After the final build's listing every one of the 19 files read since the count began was a program, library or setting of the SSH session doing the checking. Two listings running side by side were found to spoil that, because each takes the other's reading for the file's own time, so a listing now holds a lock and a second one waits.
- **A start, by the files it reads.** After a restart the listing began 2 minutes 11 seconds after the start and recorded 707 files. The earliest time on any of them was 23 seconds after the start, and 21 seconds on the restart before, which is how it was found that nothing read before the system volume is writable leaves a trace. Among the files were the programs of five app extensions, of five tools that Cydia's start-up script runs and of the untether's Wi-Fi loader, all of which had run and ended before the service wrote its first line, and none of which it had seen running. An earlier version also counted the five minutes before the start, to allow for times the file system had not yet saved, and so listed what was done just before the restart; that was taken out.
- **launchd's own counts.** All 270 services were asked about with a throwaway tool first, which also showed that launchd on iOS 9.3.5 writes its answer to a file it is handed and refuses the shared memory newer versions use. 125 had run, 22 of them had run and ended, and the 103 that were running gave six different reasons. The service asks through a file, never a pipe, so that launchd cannot be left waiting for a reader. After the restart the report listed as having run fifteen services Finch Logs never saw, `com.apple.DumpPanic` and `com.apple.datamigrator` among them.
- **In front.** Settings was opened on the iPad for 25 seconds and the device locked again: the report showed it in front once, for 25 seconds, and the count stopped at the lock although Settings was still the app behind the lock screen. Mail and Safari, which iOS starts after every start, were listed as having run without being in front.
- **Needed by Nothing Else** was read for iBooks, Maps and `com.apple.gamed`, and not checked by removing anything.
- **The app's screens** were captured on the iPad upright and on its side, and in the iPhone layout by running an iPhone-only build on the iPad at 320 by 480 points. That showed list rows overlapping at iPhone width, which were reworked; afterwards the iPhone layout was captured upright only. The What Is Installed screens were captured on the iPad both ways and in the iPhone layout both ways, and the item pages with their lists on the iPad upright and in the iPhone layout both ways. Larger iPhone screens were not seen, and no iPhone was at hand. The lists under What Was Observed, their rows and pages, the Put It Back question and the new setting were captured on the iPad upright and in the iPhone layout both ways. Files Read and its lists, the reading on an item's page, Needed by Nothing Else, and the changed What Has Run screens were captured on the iPad on its side only.

These were not tested:

- **Switching the device off and on by hand.** Every restart was made over SSH.
- **A device with a passcode.** The store is made without data protection so that the service can write before the first unlock, but the test iPad has no passcode.
- **Another jailbreak.** When added daemons start, and how late, is the untether's doing. Only iocaste was tried.
- **Apps from the App Store.** The test iPad has none, so the walk of their folders found nothing to list.
- **Setting aside a real service or app.** Beyond the 25 seconds above, only things made for the test were moved.
- **Weeks of use.** Every list here was read within hours of the count beginning, and after one start. What Looks Unused then had 71 apps that never ran and 3 that ran without being in front, 242 launch services, 55 programs, 105 frameworks, bundles and libraries, 62 bundles of data, 53 folders of other files and 52 languages on it, and those numbers will fall as the device is used.
- **The new screens in the iPhone layout.** Files Read and the other screens added last use the same lists as the ones captured there before, but were not captured there themselves.
- **A 64-bit device.** The reader of the shared library cache was written for 32-bit and 64-bit libraries and run only on a 32-bit device.

A process that lasts only a few milliseconds while the processor is saturated can exit before the service has read what it was. Such a run is noted in Processes as too short to name.

Kernel messages carry no numbers, so when the kernel prints exactly the same lines again and again the service cannot always tell how many times.

Finch Logs reads private parts of iOS that App Store apps may not use, so it works only on a jailbroken device.
