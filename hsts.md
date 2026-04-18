---
title: "HSTS Preload List Submission"
source: "https://hstspreload.org/"
language: "en"
word_count: 919
---

[On GitHub](https://github.com/chromium/hstspreload.org "On GitHub")

## HTTP Strict Transport Security (HSTS)

[HTTP Strict Transport Security (HSTS)](https://en.wikipedia.org/wiki/HTTP_Strict_Transport_Security) is a mechanism for websites to instruct web browsers that the site should only be accessed over HTTPS. This mechanism works by sites sending a `Strict-Transport-Security` HTTP response header containing the site's policy.

HSTS is supported by [most major browsers](https://caniuse.com/stricttransportsecurity). For more details on HSTS, see [RFC 6797](https://tools.ietf.org/html/rfc6797).

## Benefits of HSTS

When a web browser enforces a domain's HSTS policy, it will upgrade all `http://` URLs for that domain to HTTPS. If the policy also sets `includeSubDomains`, it will do this for all subdomains as well.

A site that enables HSTS helps protect its users from the following attacks done by an on-path attacker:

- **Browsing history leaks**: If a user clicks on an HTTP link to a site, an on-path network observer can see that URL. If the site has an HSTS policy that is enforced, the browser upgrades that URL to HTTPS and the path is not visible to the network observer.
- **Protocol downgrades**: If a site redirects from HTTP to HTTPS, an on-path network attacker can intercept and re-write the redirect to keep the browser using plaintext HTTP.
- **Cookie hijacking**: On HTTP requests, an on-path network attacker can see and modify cookies. Even if the site redirects to HTTPS, the on-path attacker can inject cookies into the redirect response.

## Submission Requirements

If a site sends the `preload` directive in an HSTS header, it is considered to be requesting inclusion in the preload list and may be submitted via the form on this site.

In order to be accepted to the HSTS preload list through this form, your site must satisfy the following set of requirements:

1. Serve a valid **certificate**.
2. **Redirect** from HTTP to HTTPS on the same host, if you are listening on port 80.
3. Serve all **subdomains** over HTTPS.
	- In particular, you must support HTTPS for the `www` subdomain if a DNS record for that subdomain exists.
		- **Note:** HSTS preloading applies to *all* subdomains, including internal subdomains that are not publicly accessible.
4. Serve an **HSTS header** on the base domain for HTTPS requests:
	- The `max-age` must be at least `31536000` seconds (1 year).
		- The `includeSubDomains` directive must be specified.
		- The `preload` directive must be specified.
		- If you are serving an additional redirect from your HTTPS site, that redirect must still have the HSTS header (rather than the page it redirects to).

For more details on HSTS, please see [RFC 6797](https://tools.ietf.org/html/rfc6797). Here is an example of a valid HSTS header:

`Strict-Transport-Security:` `max-age=63072000; includeSubDomains; preload`

You can check the status of your request by entering the domain name again in the form above, or consult the current Chrome preload list by visiting `chrome://net-internals/#hsts` in your browser. Note that new entries are hardcoded into the Chrome source code and can take several months before they reach the stable version.

## Continued Requirements

You must make sure your site continues to satisfy the submission requirements at all times. Note that removing the `preload` directive from your header will make your site immediately eligible for the [removal form](https://hstspreload.org/removal/), and that sites may be removed automatically in the future for failing to keep up the requirements.

In particular, the [requirements above](#submission-requirements) apply to all domains submitted through `hstspreload.org` on or after **October 11, 2017** (i.e. preloaded after Chrome 63)

The same requirements apply to earlier domains submitted on or after **February 29, 2016** (i.e. preloaded after Chrome 50), except that the required max-age for those domains is only `10886400` seconds.

## Preloading Should Be Opt-In

If you maintain a project that provides HTTPS configuration advice or provides an option to enable HSTS, **do not include the `preload` directive by default**. We get regular emails from site operators who tried out HSTS this way, only to find themselves on the preload list without realizing that some subdomains cannot support HTTPS. [Removal](#removal) tends to be slow and painful for those sites.

Projects that support or advise about HSTS and HSTS preloading should ensure that site operators understand the long-term consequences of preloading before they turn it on for a given domain. They should also be informed that they need to meet additional requirements and submit their site to [hstspreload.org](https://hstspreload.org/) to ensure that it is successfully preloaded (i.e. to get the full protection of the intended configuration).

## Submission Form

If you still wish to submit your domain for inclusion in Chrome's HSTS preload list and you have followed our [deployment recommendations](#deployment-recommendations) of slowly ramping up the `max-age` of your site's `Strict-Transport-Security` header, you can use this form to do so:

## Removal

Be aware that inclusion in the preload list cannot easily be undone. Domains can be removed, but it takes months for a change to reach users with a Chrome update and we cannot make guarantees about other browsers. Don't request inclusion unless you're sure that you can support HTTPS for **your entire site and all its subdomains** in the long term.

However, we will generally honor requests to be removed from Chrome's preload list if you find that you have a subdomain that you cannot serve over HTTPS for strong technical or cost reasons. To request removal, please visit the [removal form](https://hstspreload.org/removal/).

## TLD Preloading

Owners of gTLDs, ccTLDs, or any other [public suffix](https://publicsuffix.org/) domains are welcome to preload HSTS across all their registerable domains. This ensures robust security for the whole TLD, and is much simpler than preloading each individual domain. Please [contact us](https://hstspreload.org/contact) if you're interested, or would like to learn more.