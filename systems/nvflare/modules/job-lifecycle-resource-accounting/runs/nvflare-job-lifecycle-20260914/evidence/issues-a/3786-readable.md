# 3786: Make admin server timeout configurable

{'state': 'MERGED', 'headRefOid': '444c5eaa3445128fbce4dcedd50570c28a220232', 'mergeCommit': {'oid': 'e0605452edc6c6ce72a4f7bbf7ffc316f41d030d'}, 'mergedAt': '2025-10-14T01:13:32Z'}

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


## timeline-comments 3399566533 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/3786#issuecomment-3399566533; ; 
/build


## reviews 3333346863 by copilot-pull-request-reviewer[bot]; https://github.com/NVIDIA/NVFlare/pull/3786#pullrequestreview-3333346863; COMMENTED; 
## Pull Request Overview

This PR makes the admin server timeout configurable by adding an "admin_timeout" parameter to server configuration files, addressing issue #3730.

- Adds a configurable timeout parameter to the `FedAdminServer` constructor
- Updates server startup code to read the timeout from configuration files
- Provides a template example showing how to configure the timeout in resources.json

### Reviewed Changes

Copilot reviewed 3 out of 3 changed files in this pull request and generated no comments.

| File | Description |
| ---- | ----------- |
| nvflare/private/fed/server/admin.py | Adds timeout parameter to FedAdminServer constructor and uses it instead of hardcoded value |
| nvflare/private/fed/app/utils.py | Updates create_admin_server to pass timeout from server configuration |
| nvflare/lighter/templates/master_template.yml | Adds admin_timeout example to server resources template |





---

<sub>**Tip:** Customize your code reviews with copilot-instructions.md. <a href="/NVIDIA/NVFlare/new/main/.github?filename=copilot-instructions.md" class="Link--inTextBlock" target="_blank" rel="noopener noreferrer">Create the file</a> or <a href="https://docs.github.com/en/copilot/customizing-copilot/adding-repository-custom-instructions-for-github-copilot" class="Link--inTextBlock" target="_blank" rel="noopener noreferrer">learn how to get started</a>.</sub>


## reviews 3333476422 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/3786#pullrequestreview-3333476422; APPROVED; 

