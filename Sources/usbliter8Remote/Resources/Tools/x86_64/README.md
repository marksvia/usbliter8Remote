x86_64 helper tools for Intel macOS builds.

Contents:
- idevice_id, ideviceinfo, irecovery and libimobiledevice dependency dylibs.
- OpenSSL 1.1.1w x86_64 dylibs built locally from OpenSSL source.

Source:
- libimobiledevice.1.2.1-r1122-osx-x64.zip from
  https://github.com/libimobiledevice-win32/imobiledevice-net/releases/tag/v1.3.17
- OpenSSL 1.1.1w from https://www.openssl.org/source/openssl-1.1.1w.tar.gz

Notes:
- Binary install names were rewritten to use @loader_path so the tools do not
  depend on /usr/local/opt/openssl@1.1 on another Mac.
- AppResourceLocator prefers this directory only when the app is compiled for
  x86_64. arm64 builds keep using the existing bundled arm64 tools.
