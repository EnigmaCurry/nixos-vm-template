# Seed templates

Files `just create` copies into `machines/<name>/` the first time a profile
needs them. Edit a file here to change what *new* machines get; existing
machines keep their own copy — the seeder never overwrites an existing file.

| Template | Copied to | Docs |
|----------|-----------|------|
| [`wireguard.nft`](wireguard.nft) | `machines/<name>/wireguard.nft` (`wireguard` profile) | [WIREGUARD.md](../WIREGUARD.md#peer-acl-wireguardnft) |

Read by `vm.machine/seed-template`, which resolves them from the classpath
(`bb.edn` `:paths`). The remaining seed templates are still string literals
in `src/vm/machine.clj`.
