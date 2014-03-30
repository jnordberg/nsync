
nsync
=====

nsync is a commandline tool and node.js library that synchronises folders
using pluggable transports.


Quick-start
-----------

Install [node.js](http://nodejs.org/) if you haven't already.

Then install nsync:

```
npm install -g nsync
```

That will install the nsync module globally and add the `nsync` command to your path.

Now you need some transports (by default nsync can only sync files on the local filesystem, which isn't very exciting)

Lets start with the sftp transport

```
npm install -g nsync-sftp
```

Now you're all set to start syncing files. Here's an example of how to sync a directory to your webserver over ssh:

```
nsync sftp --host myserver.com --destination /var/www/my-project ~/my-project
```

Bam!


Transports
----------

TODO

 * nsync-sftp
 * nsync-s3


Contributing
------------

`NSYNC_DEV=1`


License
-------

MIT
