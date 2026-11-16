# Mixcloud Plugin for Lyrion Music Server #

This is a Lyrion Music Server (LMS) (a.k.a Squeezebox server) plugin to play tracks from Mixcloud.
It uses `ffmpeg` to transcode the Mixcloud stream.
To install, use the settings page of Lyrion Music server.
Go to the _Plugins_ tab, scroll down to _3rd party plugins_ and select Mixcloud.
Press the _Apply_ button and restart LMS.

After installation, you can configure the Plugin under _Settings_ > _Advanced_ > _Mixcloud_

The plugin is included as a default third party resource. It is retrieved from this
GitHub repository. It is also possible to directly include
the repository XML as an additional repository. For the release version, include

    https://danielvijge.github.io/lms_mixcloud/public.xml

For the development version (updated with every commit), include

    https://danielvijge.github.io/lms_mixcloud/public-dev.xml

Development builds are only available for Linux. Regular builds are released for Linux,
Windows, and MacOS.

## Favourite Mixcloud users ##

In **My Mixcloud > Following**, open a user's three-dot menu and select
**Add to Favourites** (the wording depends on your LMS controller). This uses
Lyrion's own favourites, not Mixcloud's track favourites. An already-saved user
offers **Remove from Favourites** instead, so the same user is not added twice.
Lyrion supplies the normal save/remove feedback.

Open the saved user from Lyrion's **Favourites** to browse their latest 100 uploads,
newest first, or all uploads if they have fewer. Select an individual upload to
play it just as you would under the user's **Tracks** entry. Uploads are fetched
when the feed opens; Lyrion may retain the list during the current browsing
session. The existing **Hide exclusive tracks** setting still applies, so fewer
than 100 tracks may be visible. Reposts and Mixcloud track favourites are not
included.

Saved users use a `mixclouduser://` feed handled by this plugin. They do not store
an access token, server address, raw API feed, or a temporary menu identifier.
Keep the plugin enabled to open them. Remove any broken favourites saved by older
experiments as API URLs or `index.html?username=...`, then add the users again.

### Trying this fork before a release ###

The upstream installation and repository URLs above do **not** install this
fork's changes. On a working Mixcloud installation:

1. Stop LMS and back up the installed Mixcloud plugin.
2. Replace `Plugin.pm`, `ProtocolHandler.pm`, and `strings.txt` in the installed
   `Plugins/MixCloud` directory with the files from this branch, keeping their
   permissions/ownership. On a typical Linux installation this is under
   `/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/MixCloud`; use the
   plugin location reported by your own server if different.
3. Restart LMS, confirm Mixcloud is enabled and connected to your account, then
   add a user through **My Mixcloud > Following**.

An upstream plugin update can overwrite manually installed changes. Authentication
requires LMS 9.2.0 builds after 18 June 2026, as noted in the plugin's startup
warning. Existing playback requirements below are unchanged.

### Development checks ###

Run `prove -v t/user-favourites.t` with Perl and the plugin's non-LMS dependencies
(`JSON::XS`, `URI::Escape`, `Date::Parse`, `Data::Dump`, `HTTP::Request`,
`HTML::Parser`, and `XML::Simple`) available. The tests load and execute both real
plugin modules, including track parsing, with LMS services and HTTP responses
doubled. They cover favourite metadata, startup routing, the 100-upload bound,
pagination, filtering, authentication, metadata callbacks, and visible failures.
They do not replace testing the three-dot menu, favourite persistence across an
LMS restart, and actual audio playback on a running LMS installation.

## ffmpeg ##

`ffmpeg` must be installed to transcode the Mixcloud stream to a stream that can be played directly by LMS.
On Debian Linux this can be installed like this:

    sudo apt install ffmpeg

When using the official Docker image, refer to the documentation how to install `ffmpeg` every time a new version is pulled.

The type of transcoding can be configured via _Settings_ > _Advanced_ > _File Types_.
Available options are flac, pmc, or mp3. Transcoding to mp3 also requires `lame` to be installed.

## Running on the official LMS docker image

This plugin uses `yt-dlp` to retrieve a playable stream URL.
This does not work by default on the official docker image of LMS.
Trying to play a Mixcloud stream on LMS running on the official docker image gives an error message:

    /usr/bin/env: python3: No such file or directory

The official docker image does not contain `python3`, but python 3.10 is required by the bundled version of the helper application (`yt-dlp`).
See [this issue in the issue tracker](https://github.com/danielvijge/lms_mixcloud/issues/36) for suggested solutions.

## Licence ##

This work is distributed under the GNU General Public License version 2. See file LICENSE for
full license details.
