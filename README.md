**As of Warp 3.3.20, there is a flag `x509` which controls whether TLS parts are included in the build.  I tested this and compared it to `plain-warp`, and verified that it was equally effective in eliminating dependencies.  As such, this package is no longer necessary and I'm abandoning it.**

`plain-warp` is an experimental fork of [Warp](https://github.com/yesodweb/wai/tree/master/warp), a Haskell webserver, where I have crudely ripped out the TLS/certificate/security parts.  Why?

1.  They require a lot of dependencies.  Of the 41 packages that have to be installed to build Warp, 9 are just to serve the certificate features, and some of those are quite large.

2.  A common topology is to have something in front of the core webserver, such as a load balancer, an accelerator, a proxy, or even a simple relay, and these often provide TLS termination.

3.  The Haskell TLS ecosystem is behind the times in security, missing modern features such as OCSP stapling, so that if you want a full webserver for today, you pretty much need to do (2).


# Warp

Warp is a server library for HTTP/1.x and HTTP/2 based WAI(Web Application Interface in Haskell). For more information, see [Warp](http://www.aosabook.org/en/posa/warp.html).
