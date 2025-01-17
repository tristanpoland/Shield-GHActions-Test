SHIELD Genesis Kit
==================

This is a Genesis Kit for the [SHIELD Data Protection System][1],
from [Stark & Wayne][2]. When using [genesis][3] to deploy this kit,
you will get a fully-functional SHIELD deployment for backing up + restoring
your data services.

Quick Start
-----------

To use it, you don't even need to clone this repository!  Just run
the following (using Genesis v2):

```
# create a shield-deployments repo using the latest version of the SHIELD kit
genesis init --kit shield

# create a shield-deployments repo using v1.0.0 of the SHIELD kit
genesis init --kit shield/1.0.0

# create a my-shield-configs repo using the latest version of the SHIELD kit
genesis init --kit shield -d my-shield-configs
```

Once created, refer to the deployment repo's README for information on creating
new environments + deploying them.

Learn More
----------

For more in-depth documentation, check out the [manual][5].

[1]: https://github.com/starkandwayne/shield
[2]: https://starkandwayne.com
[3]: https://github.com/starkandwayne/genesis
[4]: https://github.com/cloudfoundry/uaa
[5]: MANUAL.md
