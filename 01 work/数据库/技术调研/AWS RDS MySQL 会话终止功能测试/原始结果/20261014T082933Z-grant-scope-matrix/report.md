# AWS RDS MySQL EXECUTE grant-scope evidence

- Run ID: `20261014T082933Z`
- Scopes: global, database (`mysql.*`), procedure
- Each scope: without/with GRANT OPTION, multi-hop delegation, and upstream
  revocation with downstream-retention check
- Both RDS kill procedures are checked for scope isolation

An expected `ERROR 1094` proves routine entry; `ERROR 1370` proves denial.
Review `status.tsv`, individual logs, and final grants together.
