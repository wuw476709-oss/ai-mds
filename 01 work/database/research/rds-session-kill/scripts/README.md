# AWS RDS for MySQL session-kill probe

This harness implements the safe, automatable core of the exploratory test plan
in `../docs/aws-rds-mysql-session-kill-exploratory-test-plan.md`.

It determines whether `mysql.rds_kill` and `mysql.rds_kill_query` are usable by:

- the RDS master user;
- an ordinary account;
- an account with `PROCESS`;
- an account granted procedure-level `EXECUTE`;
- a non-master account with `rds_superuser_role`, inactive and active.

It also verifies the observable difference between query termination and session
termination, then checks behavior after `REVOKE`.

## Safety

- Run only against an isolated, disposable RDS for MySQL instance.
- The harness creates accounts and a database with the configured unique prefix.
- It discovers and terminates only connections authenticated as its dedicated
  target users.
- It never calls a kill procedure for `rdsadmin`, `rdsrepladmin`, replication,
  backup, monitoring, or unidentified threads.
- Passwords are not written to the result directory.
- The default behavior removes all disposable objects after collecting evidence.

## Prepare the instance

1. Create an RDS for MySQL instance of the exact version being investigated.
2. Do not attach production workloads, replicas, or external monitoring that
   depends on test accounts.
3. Allow inbound TLS MySQL traffic from the machine running this harness.
4. Install a MySQL client compatible with the server.

## Configure

Copy `config.example.cnf` outside the repository, fill in the endpoint, master
user, and password, and restrict it:

```bash
cp config.example.cnf /private/path/aws-rds-test.cnf
chmod 600 /private/path/aws-rds-test.cnf
```

Copy `test.env.example`, set `CSK_ADMIN_CNF`, `CSK_ENDPOINT`, and the desired
unique prefix. Do not put the master password in this environment file.

## Run

```bash
chmod +x run.sh cleanup.sh
./run.sh /absolute/path/to/test.env
```

The last output line is the result directory. It contains:

- `report.md`: automatically rendered observation table;
- `cases.tsv`: machine-readable case outcomes;
- `metadata/`: version, identity, procedure metadata, grants, and GRANT/REVOKE results;
- `targets/`: target-client output proving whether its connection survived;
- one call log per case.
- `raw-mysql/manifest.tsv`: byte count and checksum for every raw evidence file;
- `raw-mysql/mysql-output.log`: unmodified MySQL stdout/stderr concatenated with
  file boundaries for later comparison;
- `raw-mysql/mysql-errors.tsv`: extracted ERROR/WARNING lines with source file
  and line number.

The runner calls `collect-results.sh` automatically. It is idempotent and can
also add the same raw-output bundle to an older result directory:

```bash
./collect-results.sh /absolute/path/to/results/RUN_ID
```

The generated report is evidence, not the final interpretation. Review routine
metadata and failed GRANT statements before deciding whether AWS checks master
identity, role membership, EXECUTE privilege, or an internal policy.

## Grant-chain and reserved-account boundary probe

After the core run has created the prefixed test users, run:

```bash
./run-grant-and-reserved-boundaries.sh /absolute/path/to/test.env
```

This supplementary probe tests global `EXECUTE` with and without
`GRANT OPTION`, verifies whether a recipient can continue the grant chain, and
collects the reserved-user table and procedure definitions. It never sends a
kill request to an AWS internal thread. A trap revokes only the temporary
global `EXECUTE` privileges; it does not delete the test database/users or
remove existing procedure-level grants.

## Persistent-session and runtime-semantics probe

Run the deep probe after the core accounts and database have been prepared:

```bash
./run-deep-semantics.sh /absolute/path/to/test.env
```

It automates the cases that previously remained manual:

- GRANT and REVOKE observed by the same already-connected client;
- revocation of an active `rds_superuser_role` in the same connection;
- true self-termination using `CONNECTION_ID()`;
- `rds_kill_query` against an idle connection;
- transaction and row-lock behavior after query and connection termination;
- native `KILL QUERY`/`KILL CONNECTION` authorization as a comparison;
- the complete input-conversion matrix for both procedures, including a
  prepared call.

The probe creates dedicated suffixes (`_life`, `_dx`, `_dt`, `_dp`, `_dr`) and
the table `deep_lock_probe`. With `CSK_KEEP_OBJECTS=1` (the recommended setting
for exploratory work), these objects remain for inspection. It never targets
AWS reserved/internal sessions.

## Complete EXECUTE grant-scope matrix

To test global, database, and procedure scope independently, including
multi-hop delegation and non-cascading upstream revocation, run:

```bash
./run-grant-scope-matrix.sh /absolute/path/to/test.env
```

The script uses dedicated `_g1`, `_g2`, and `_g3` users. Global and `mysql.*`
privileges are always revoked after their cases. Set
`CSK_KEEP_FINAL_PROCEDURE_CHAIN=1` only to retain the final
`mysql.rds_kill_query` procedure-level delegation chain for inspection; it
never retains a global or database-level `EXECUTE`/`GRANT OPTION` chain.

## rds_superuser_role delegation

Run the role-specific probe with:

```bash
./run-role-delegation.sh /absolute/path/to/test.env
```

It tests role grant without and with `ADMIN OPTION`, a three-user role chain,
and downstream behavior after the first recipient is revoked. Role grants are
always revoked at the end; the dedicated `_r1`, `_r2`, `_r3` accounts remain
when `CSK_KEEP_OBJECTS=1`.

## Manual cleanup

The default run cleans up automatically. If the run is interrupted or
`CSK_KEEP_OBJECTS=1` was used:

```bash
./cleanup.sh /absolute/path/to/test.env
```

## Follow-up manual phases

The following cases remain deliberately manual because they are destructive,
version-specific, or require careful transaction coordination:

- explicit testing of the master user as a target when using an account other
  than the dedicated administrator control connection;
- simultaneous callers and thread-ID reuse pressure;
- old-version usernames longer than 16 characters;
- restart, failover, minor-version upgrade, and cross-version comparison.

Never extend those cases to AWS internal or replication threads.

## Reserved-account dynamic guard probe

`run-reserved-account-dynamic.sh` is a separately gated, query-only probe. It
selects only an exact `mysql.rds_reserved_users` match for an idle `rdsadmin`
session, calls `rds_kill_query`, and verifies the same target afterwards. It
never contains or sends `rds_kill`, and never selects active, replication,
backup, or non-reserved threads. A connection-kill probe, if explicitly
approved, must be a separate second-stage action after reviewing this output.
The separately authorized second stage is
`run-reserved-account-session-stage.sh`; it requires the query-stage result
directory, validates its 1644 evidence, and rechecks the same target before it
can send `rds_kill`.
