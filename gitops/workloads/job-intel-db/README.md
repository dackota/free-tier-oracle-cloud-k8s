# job-intel-db

pgvector Postgres backing the job-intel pipeline. The Postgres password is a
git-invisible prerequisite Secret (`job-intel-db`, key `postgresql-password`),
created by hand.

Full deploy steps — including this Secret, the app Secret, chart vendoring, and
DNS — are in the sibling runbook: [`../job-intel/README.md`](../job-intel/README.md).
