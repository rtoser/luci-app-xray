# Contributing

This fork follows the upstream GitHub branch protection rule:

- Commits in pull requests must have **verified signatures**.

If a commit is not verified, PR merge will be blocked.

## Recommended: SSH commit signing

Use your SSH key as the Git signing key (example uses `~/.ssh/id_ed25519.pub`):

```sh
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
```

Set the author email to the one associated with your GitHub account:

```sh
git config --global user.email "yourpublicemail@github.settings"
```

## Verify before pushing

Check the latest commit signature locally:

```sh
git log --show-signature -n 1
```

After pushing, check GitHub shows **Verified** on the commit in the PR.

## If you already pushed an unsigned commit

Rewrite the latest commit with a signature, then force-push:

```sh
git commit --amend --no-edit -S
git push --force-with-lease
```
