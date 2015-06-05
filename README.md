## Docker-Nagios  [![Docker Build Status](http://72.14.176.28/imprev/nagios)](https://registry.hub.docker.com/u/imprev/nagios)

NOTE: This is a fork of the very good Docker image from cpuguy83/nagios.  We needed a few more packages and symlinks that may not be necessary for you.  We also included a sample SystemD unit file which includes the switches for keeping most of your config outside the environment.  In our case, we were migrating from a current Nagios setup.

Basic Docker image for running Nagios.<br />
This is running Nagios 3.5.1

You should either link a mail container in as "mail" or set MAIL_SERVER, otherwise
mail will not work.

### Knobs ###
- NAGIOSADMIN_USER=nagiosadmin
- NAGIOSAMDIN_PASS=nagios

### Web UI ###
The Nagios Web UI is available on port 80 of the container<br />
