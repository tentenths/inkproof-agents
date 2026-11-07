Put each agent's GitHub tokens here, one token per file, no trailing text:

    secrets/<agent>/write-token   own repository
    secrets/<agent>/read-token    repositories it depends on

At autonomy level 3, also the GitHub App's private key, which only the
gatekeeper container mounts:

    secrets/gatekeeper/app-key.pem

Never commit these files (see .gitignore). See the main README for the
permissions each token needs.
