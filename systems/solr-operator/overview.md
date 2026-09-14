# Apache Solr Operator

## Scope

Specula analyzed and tested the Apache Solr Operator's reconciliation with Kubernetes and SolrCloud, including managed updates, scaling, asynchronous backups, BasicAuth initialization, cross-namespace exporter references, and public status.

## Bugs

Specula recorded 5 new findings and 1 previously known bug:

- Scale-down submits `REPLACENODE` when fewer than two Solr nodes are live, leaving the operation and its lock in a retry loop until another destination becomes available.
- **Environment-limited:** Managed update can remove the only active NRT/TLOG replica while a PULL replica remains active, potentially leaving the shard without a write-capable leader.
- Relisting collections can drop an already-submitted collection from SolrBackup polling, leaving the backup and its recurrence nonterminal after that collection is deleted.
- A partial generated-BasicAuth Secret creation can be treated as complete on the next reconcile, allowing Solr to become Ready without the requested BasicAuth configuration.
- A referenced SolrCloud change does not enqueue a cross-namespace exporter, leaving its Deployment on an old image and ZooKeeper target while status remains Ready.
- **Known:** `DELETESTATUS` can remove the terminal async record before backup status is durable; controller loss then leaves SolrBackup polling `notfound` indefinitely, as reported in [issue #824](https://github.com/apache/solr-operator/issues/824).
