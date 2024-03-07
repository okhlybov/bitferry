# Bitferry - file synchronization/backup automation

<div align="right"><i>Ein Backup ist kein Backup</i></div><br><br>

The [Bitferry](https://github.com/okhlybov/bitferry) is aimed at establishing the automated file synchronization/replication/backup routes between multiple endpoints where the latter can be the local directories, online cloud remotes or portable offline storages.

The intended usage ranges from maintaining simple directory copy to another location (disk, mount point) to complex many-to-many (online/offline) data replication/backup solution employing portable media as additional data storage and a means of data propagation between the offsites.

The core idea that drives Bitferry is the conversion of full (absolute) endpoint's paths into the volume-relative ones, where the volume is a data file which is put along the endpoint's data and denotes the root of the directory hierarchy. This leads to the important location independence property meaning that Bitferry is then able to restore the tasks' source-destination endpoint connections in spite of the volume location changes, which is a likely scenario in case of portable storage (different UNIX mount points, Windows drives etc.).

Bitferry is effectively a frontend to the [Rclone](https://rclone.org) and [Restic](https://restic.net) utilities.

## Features

* Multiplatform (Windows / UNIX / macOSX) operation

* Automated task-based data processing

* One way / two way data synchronization

* Recursive directory copy / update / synchronize

* Incremental directory backup with snapshotting

* File/repository password-based end-to-end encryption

* Online cloud storage relay

* Offline portable storage (USB flash, HDDs, SSDs etc.) relay

## Use cases

* Maintain an update-only files copy in a separate location on the same site

* Maintain offline secure two way file synchronization between two offsites

* Maintain an incremental files backup on a portable medium with multiple offsite copies of the repository

## Implementation

The Bitferry itself is written in [Ruby](https://www.ruby-lang.org) programming language. Being a Ruby code, the Bitferry requires the platform-specific Ruby runtime, version 3.0 or higher. 

The source code is hosted on [GitHub](https://github.com/okhlybov/bitferry) and the binary releases in form of a GEM package are distributed through the [RubyGems](https://rubygems.org/gems/bitferry) repository channel.

In addition, the platform-specific [Rclone](https://github.com/rclone/rclone/releases) and [Restic](https://github.com/restic/restic/releases) executables are required to be accessible through the `PATH` directory list or through the respective `RCLONE` and `RESTIC` environment variables.

## Kickstart

### Install Bitferry

```shell
gem install bitferry
```

### Prepare source Bitferry volume for a mounted local filesystem

```shell
bitferry create volume /data
```

### Prepare destination Bitferry volume for a mounted portable storage

```shell
bitferry create volume /mnt/usb-drive
```

### Ensure the volumes are intact

```shell
bitferry show
```

```
# Intact volumes

  d2f10024    /data
  e42f2d8c    /mnt/usb-drive
```

### Create a (Rclone) sync task with data encryption

```shell
bitferry create task sync -e /data /mnt/usb-drive/backup
```

### Review the changes

```shell
bitferry
```

```
# Intact volumes

  d2f10024    /data
  e42f2d8c    /mnt/usb-drive


# Intact tasks

  89e1c119    encrypt+synchronize :d2f10024: --> :e42f2d8c:backup
```

### Perform a dry run of the specific task

```shell
bitferry process -vn 89e
```

<details>
<summary>...</summary>

```
rclone sync --filter -\ .bitferry --filter -\ .bitferry\~ --verbose --progress --dry-run --metadata --crypt-filename-encoding base32 --crypt-filename-encryption standard --crypt-remote /mnt/usb-drive/backup /data :crypt:
2024/03/05 11:46:45 NOTICE: README.md: Skipped copy as --dry-run is set (size 3.073Ki)
2024/03/05 11:46:45 NOTICE: LICENSE: Skipped copy as --dry-run is set (size 1.467Ki)
2024/03/05 11:46:45 NOTICE: bitferry.gemspec: Skipped copy as --dry-run is set (size 996)
Transferred:        5.513 KiB / 5.513 KiB, 100%, 0 B/s, ETA -
Transferred:            3 / 3, 100%
Elapsed time:         0.0s
2024/03/05 11:46:45 NOTICE: 
Transferred:        5.513 KiB / 5.513 KiB, 100%, 0 B/s, ETA -
Transferred:            3 / 3, 100%
Elapsed time:         0.0s
```

</details>

### Process all intact tasks in sequence

```shell
bitferry -v x
```

<details>
<summary>...</summary>

```
rclone sync --filter -\ .bitferry --filter -\ .bitferry\~ --verbose --progress --metadata --crypt-filename-encoding base32 --crypt-filename-encryption standard --crypt-remote /mnt/usb-drive/backup /data :crypt:
2024/03/05 11:44:31 INFO  : LICENSE: Copied (new)
2024/03/05 11:44:31 INFO  : README.md: Copied (new)
2024/03/05 11:44:31 INFO  : bitferry.gemspec: Copied (new)
Transferred:        5.653 KiB / 5.653 KiB, 100%, 0 B/s, ETA -
Transferred:            3 / 3, 100%
Elapsed time:         0.0s
2024/03/05 11:44:31 INFO  : 
Transferred:        5.653 KiB / 5.653 KiB, 100%, 0 B/s, ETA -
Transferred:            3 / 3, 100%
Elapsed time:         0.0s
```

</details>

### Observe the result

```shell
ls -l /mnt/usb-drive/backup
```

<details>
<summary>...</summary>

```
-rw-r--r-- 1 user user 1044 feb 27 17:09 0u1vi7ka5p88u62kof9k6mf2z00354g6fa0c9a0g6di2f0ocds80
-rw-r--r-- 1 user user 1550 jan 29 11:57 21dgu5vs2c4rjfkieeemjvaf78
-rw-r--r-- 1 user user 3195 mar  5 11:43 m9rhq3q2m5h2q5l1ke00u0gdjc
```

</details>

### Examine the detailed usage instructions

```shell
bitferry c t s -h
```

<details>
<summary>...</summary>

```
Usage:
    bitferry c t s [OPTIONS] SOURCE DESTINATION

  Create source --> destination one way file synchronization task.

  The task operates recursively on two specified endpoints.
  This task copies newer source files while skipping unchanged files in destination.
  Also, it deletes destination files which are non-existent in source.

    The endpoint may be one of:
    * directory -- absolute or relative local directory (/data, ../source, c:\data)
    * local:directory, :directory -- absolute local directory (:/data, local:c:\data)
    * :tag:directory -- path relative to the intact volume matched by (partial) tag (:fa2c:source/data)

    The former case resolves specified directory againt an intact volume to make it volume-relative.
    It is an error if there is no intact volume that encompasses specified directory.
    The local: directory is left as is (not resolved against volumes).
    The :tag: directory is bound to the specified volume.



    The encryption mode is controlled by --encrypt or --decrypt options.
    The mandatory password will be read from the standard input channel (pipe or keyboard).

  This task employs the Rclone worker.

Parameters:
    SOURCE                   Source endpoint specifier
    DESTINATION              Destination endpoint specifier

Options:
    -e                       Encrypt files in destination using default profile (alias for -E default)
    -d                       Decrypt source files using default profile (alias for -D default)
    -x                       Use extended encryption profile options (applies to -e, -d)
    --process, -X OPTIONS    Extra task processing profile/options
    --encrypt, -E OPTIONS    Encrypt files in destination using specified profile/options
    --decrypt, -D OPTIONS    Decrypt source files using specified profile/options
    --version                Print version
    --verbose, -v            Extensive logging
    --quiet, -q              Disable logging
    --dry-run, -n            Simulation mode (make no on-disk changes)
    -h, --help               print help
```

</details>

## The rest is about to come

*Cheers!*

Oleg A. Khlybov <fougas@mail.ru>
