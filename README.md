# oxide-field-notes

Working notes from fielding Oxide systems into real environments: getting an awkward guest OS to boot, wiring up networking, automating with the `oxide` CLI and API. Each note gives the exact commands, what was verified on real hardware, and what was not.

This is a personal, unofficial collection. It is not an Oxide product and carries no support commitment. For Oxide-developed integrations and accessory software, see [oxidecomputer/showcase](https://github.com/oxidecomputer/showcase).

## Notes

| Note | What it shows | Verified | Status |
| --- | --- | --- | --- |
| [enterprise-linux/oracle-linux](notes/enterprise-linux/oracle-linux/) | Remaster an Oracle Linux 7.9 to 10.2 ISO for serial console and unattended kickstart install and boot with cloud-init key injection | 7.9 and 10.2 on a real rack, 2026-11-04; 8.10 and 9.8 in a local UEFI VM | Candidate for internal docs |

Status is one of `Draft`, `Field-tested`, or `Candidate for internal docs` (ready to be generalized into a guide in the internal docs repo).

## Conventions

Every note lives in `notes/<slug>/` with a `README.md` that follows [NOTE-TEMPLATE.md](NOTE-TEMPLATE.md). Vendor media (ISOs, images) is never committed; notes ship the scripts that transform media the reader downloads themselves. Anything not run end to end on real hardware is labelled as untested. Customer, rack and project names stay out of the repo.
