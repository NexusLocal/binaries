# Keys of the publishers

`scripts/update-sources.sh` checks the PGP signature of each new source that has no checksum of
upstream, with these keys only (group 8, decision 8). A signature with another key makes the update
fail. Then check the new key yourself and add it here.

The keys were fetched on 2026-11-25. Each one verified the signature of the source in `sources.lock`
of that day.

| File | Signs | Key (fingerprint) | Fetched from |
| --- | --- | --- | --- |
| `nginx.asc` | nginx | `43387825DDB1BB97EC36BA5D007C8D7C15D87369`, `D6786CE303D9A9022998DC6CC8464D549AF75C0A`, `7338973069ED3F443F4D37DFA64FD5B17ADB39A8`, `13C82A63B603576156E30A4EA0EA981B66B0D967` | https://nginx.org/keys/ |
| `gnu.asc` | m4, autoconf, gettext, gmp | `71C2CC22B1C4602927D2F3AAA7A16B4A2527436A`, `82F854F3CE73174B8B63174091FCC32B6769AA64`, `E0FFBD975397F77A32AB76ECB6301D9E1BBEAC08`, `343C2FF0FBEE5EC2EDBEF399F3599FF828C67298` | https://ftp.gnu.org/gnu/gnu-keyring.gpg |
| `freetype.asc` | FreeType | `E30674707856409FF1948010BE6C3AAC63AD8E3F` (Werner Lemberg) | keyserver.ubuntu.com |
| `libwebp.asc` | libwebp | `6B0E6B70976DE303EDF2F601F9C3D6BDB8232B5D` (WebP release signing key) | keyserver.ubuntu.com |
| `openldap.asc` | OpenLDAP | `3CE269B5398BC8B785645E987F67D5FD1CE1CBCE` | https://www.openldap.org/software/download/OpenLDAP/gpg-pubkey.txt |
| `mysql.asc` | MySQL, the archives of the server and of the source | `BCA43417C3B485DD128EC6D4B7B3B788A8D3785C` (MySQL Release Engineering) | https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 |

A new key goes in the file of its publisher:

```bash
gpg --armor --export-options export-minimal --export <fingerprint> >> keys/<publisher>.asc
```
