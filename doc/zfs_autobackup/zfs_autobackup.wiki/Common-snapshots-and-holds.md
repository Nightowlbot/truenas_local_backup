## Common snapshots and holds

![image](https://user-images.githubusercontent.com/1179017/165788773-b6e1301d-bc55-4b17-9ef0-a327e791b765.png)

If you're new to ZFS these terms can be quite confusing. Whats going on?

**TLDR:** never use --no-holds

## Common snapshots

ZFS can do incremental transfers via snapshots. It does this very efficiently by sending over the differences between two snapshots. 

There are a few rules for ZFS however:

* The same starting snapshot has to exist on both target and source. So its a common snapshot.
* There cant be any newer snapshots on the target. (Normally should not happen, otherwise use --destroy-incompatible)
* Encryption has to be compatible (See [[Encryption]])

**If there is no snapshot in common, the only way to continue is to destroy the whole dataset (and all its snapshots) on the target and start from a full backup.**

## Holds to the rescue

To prevent accidental deletion of the common snapshot we use "holds". A snapshot that is held cannot be destroyed, until its released with `zfs release`. (Use `zfs holds` to see the holds for a specific snapshot)

zfs-autobackup will automatically hold the common snapshot on both sides. It will automatically release them as soon as there is a newer common snapshot. 

This can be quite frustrating for new users who try to delete old datasets that still have holds. (`Dataset is busy`) So you might be tempted to use `--no-holds`. Usually this is fine, but keep on reading.

## Holds and offline backups

For offline backups holds are even more important.

Normally when you split up the snapshotting part and backupping part you would do it like this: [[https://github.com/psy0rz/zfs_autobackup/wiki#splitting-up-snapshot-and-backup-job]]

The snapshotter will still connect to the target server and figure out the common snapshot so that they wont be destroyed. It can also cleanup old snapshots from the source if it sees that target doesn't need them (anymore)

However, if you have an offline backup (e.g. a USB disk that you sometimes connect), you are forced to use the snapshot-only tool. You would just run zfs-autobackup without specifying a target dataset or ssh-target. In that case it only makes snapshots and cleans up old snapshots according to the --keep-source schedule.

Now holds are very important: In snapshot-only mode it looks at the holds to see which snapshots are common. Otherwise it might accidentally destroy them if you have a tight --keep-source schedule.





