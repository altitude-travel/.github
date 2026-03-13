# Security Policy

## Reporting a Vulnerability

To report a security vulnerability, please follow these steps:

1. **For non-critical issues**:
   [Open a new issue](https://3.basecamp.com/6068767/buckets/44294088/card_tables/lists/9152530173/cards/new?modal=true)
   and select the "Bug Report" template. Add the `security` label to your issue.
   For example: `[Web][Security]: My issue title`.
2. **For critical vulnerabilities**: Please report them by reaching out to the
   core maintainers directly (see the [Contacts section](#contacts) below).

Security issues are a priority, and we aim to resolve them within 48 hours. If
we cannot resolve a security vulnerability within our own code, we will raise
the issue upstream with relevant parties such as 3rd party package maintainers
where possible.

## Security Updates

We regularly update our dependencies to patch security vulnerabilities. We use
Dependabot to automate this process, which creates pull requests for security
updates weekly. These pull requests are automatically merged by Dependabot if
they pass CI checks and do not introduce any breaking changes.

## Contacts

For **critical** security issues, please tag:

- **James Robb** [iOS] ([@jamesrweb](https://github.com/jamesrweb))
- **Oltion Zefi** [Web] ([@oltionzefi](https://github.com/oltionzefi))

## Disclosure Policy

When we receive a security bug report, we will:

1. Confirm the vulnerability and determine its impact
2. Develop a fix and release it according to severity
3. Publish a security advisory if necessary

We appreciate your help in keeping
[@altitude-travel](https://github.com/altitude-travel) secure!
