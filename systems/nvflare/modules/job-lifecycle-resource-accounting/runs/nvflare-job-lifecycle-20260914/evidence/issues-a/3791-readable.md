# 3791: [2.6] Make admin server timeout configurable (#3786)

{'state': 'MERGED', 'headRefOid': '2d71b9a80b786ed777906e1e0fefc81cee811098', 'mergeCommit': {'oid': '0ef0dd186764f00dda6cc3b6610b730392ede1cd'}, 'mergedAt': '2025-10-15T20:42:02Z'}

## Body
Fixes #3730 .

### Description

Make admin server timeout configurable VIA "admin_timeout" in "local/resources.json" inside a startup kit, for example:


```
$ cat ./workspace/example_project/prod_00/server1/local/resources.json.default 
{
    "format_version": 2,
    "servers": [
        {
            "admin_storage": "transfer",
            "max_num_clients": 100,
            "heart_beat_timeout": 600,
            "download_job_url": "http://download.server.com/",
            "admin_timeout": 10.0
        }
    ],
```

### Types of changes
<!--- Put an `x` in all the boxes that apply, and remove the not applicable items -->
- [x] Non-breaking change (fix or new feature that would not break existing functionality).
- [ ] Breaking change (fix or new feature that would cause existing functionality to change).
- [ ] New tests added to cover the changes.
- [ ] Quick tests passed locally by running `./runtest.sh`.
- [ ] In-line docstrings updated.
- [ ] Documentation updated.

---------

Fixes # .

### Description

A few sentences describing the changes proposed in this pull request.

### Types of changes
<!--- Put an `x` in all the boxes that apply, and remove the not applicable items -->
- [x] Non-breaking change (fix or new feature that would not break existing functionality).
- [ ] Breaking change (fix or new feature that would cause existing functionality to change).
- [ ] New tests added to cover the changes.
- [ ] Quick tests passed locally by running `./runtest.sh`.
- [ ] In-line docstrings updated.
- [ ] Documentation updated.


## timeline-comments 3407644910 by YuanTingHsieh; https://github.com/NVIDIA/NVFlare/pull/3791#issuecomment-3407644910; ; 
/build


## reviews 3337857095 by copilot-pull-request-reviewer[bot]; https://github.com/NVIDIA/NVFlare/pull/3791#pullrequestreview-3337857095; COMMENTED; 
## Pull Request Overview

This pull request makes the admin server timeout configurable by adding an "admin_timeout" parameter to server configuration. Previously, the timeout was hardcoded to 10.0 seconds.

- Added configurable timeout parameter to `FedAdminServer` constructor
- Modified server creation to read timeout from configuration with 10.0 as default
- Updated template configuration to include the new admin_timeout setting

### Reviewed Changes

Copilot reviewed 3 out of 3 changed files in this pull request and generated 1 comment.

| File | Description |
| ---- | ----------- |
| nvflare/private/fed/server/admin.py | Added timeout parameter to constructor and replaced hardcoded timeout value |
| nvflare/private/fed/app/utils.py | Modified admin server creation to read timeout from server configuration |
| nvflare/lighter/templates/master_template.yml | Updated template to include admin_timeout configuration option |





---

<sub>**Tip:** Customize your code reviews with copilot-instructions.md. <a href="/NVIDIA/NVFlare/new/main/.github?filename=copilot-instructions.md" class="Link--inTextBlock" target="_blank" rel="noopener noreferrer">Create the file</a> or <a href="https://docs.github.com/en/copilot/customizing-copilot/adding-repository-custom-instructions-for-github-copilot" class="Link--inTextBlock" target="_blank" rel="noopener noreferrer">learn how to get started</a>.</sub>


## reviews 3337942519 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/3791#pullrequestreview-3337942519; APPROVED; 



## inline-comments 2430732127 by Copilot; https://github.com/NVIDIA/NVFlare/pull/3791#discussion_r2430732127; ; nvflare/lighter/templates/master_template.yml
The removal of 'num_server_workers' and 'compression' configuration options appears unrelated to adding admin_timeout. These changes should be separated or explained as they may affect existing functionality.
```suggestion
              "admin_timeout": 10.0,
              "num_server_workers": 4,
              "compression": "auto"
```
