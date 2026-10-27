# AWS RDS MySQL deep session-kill evidence

- Run ID: `20261014T084300Z`
- Endpoint: `database-1.ctoqyyqe8wbe.eu-north-1.rds.amazonaws.com:3306`
- Raw status: `status.tsv`

This run covers persistent-session GRANT/REVOKE, active-role revocation, true
self-kill, idle targets, transaction/lock aftermath, native KILL separation,
and the two-procedure parameter matrix. Errors are evidence: in particular,
1094 means routine execution was authorized but the thread did not exist,
while 1370 means EXECUTE was denied.

AWS reserved/internal sessions were not targeted.
