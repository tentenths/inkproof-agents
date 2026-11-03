Put each agent's GitHub tokens here, one token per file, no trailing text:

    secrets/<agent>/write-token   own repository
    secrets/<agent>/read-token    repositories it depends on

Never commit these files (see .gitignore). See the main README for the
permissions each token needs.
