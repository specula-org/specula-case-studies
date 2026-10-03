module specula.local/etcd-raft-mc2

go 1.13

require go.etcd.io/etcd/raft v0.0.0

replace go.etcd.io/etcd/raft => ../../../source

replace go.etcd.io/etcd/pkg => /home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/build/legacy-pkg
