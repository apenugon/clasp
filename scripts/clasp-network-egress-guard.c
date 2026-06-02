#define _GNU_SOURCE

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

typedef int (*connect_fn)(int, const struct sockaddr *, socklen_t);

static connect_fn real_connect_fn(void) {
  static connect_fn cached = 0;
  if (cached == 0) {
    cached = (connect_fn)dlsym(RTLD_NEXT, "connect");
  }
  return cached;
}

static int allowlist_matches(int family, const char *address, unsigned int port) {
  const char *raw = getenv("CLASP_NETWORK_EGRESS_ALLOWED");
  const char *cursor = raw;

  if (raw == 0 || raw[0] == '\0') {
    return 0;
  }

  while (cursor != 0 && cursor[0] != '\0') {
    int allowed_family = 0;
    unsigned int allowed_port = 0;
    int consumed = 0;
    char allowed_address[INET6_ADDRSTRLEN];

    memset(allowed_address, 0, sizeof(allowed_address));
    if (sscanf(cursor, "%d,%45[^,;],%u%n", &allowed_family, allowed_address, &allowed_port, &consumed) == 3) {
      if (allowed_family == family && allowed_port == port && strcmp(allowed_address, address) == 0) {
        return 1;
      }
      cursor += consumed;
    }

    while (cursor[0] != '\0' && cursor[0] != ';') {
      cursor += 1;
    }
    if (cursor[0] == ';') {
      cursor += 1;
    }
  }

  return 0;
}

static int inet_allowed(const struct sockaddr *addr) {
  char address[INET6_ADDRSTRLEN];
  unsigned int port = 0;

  memset(address, 0, sizeof(address));

  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *inet_addr = (const struct sockaddr_in *)addr;
    if (inet_ntop(AF_INET, &(inet_addr->sin_addr), address, sizeof(address)) == 0) {
      return 0;
    }
    port = (unsigned int)ntohs(inet_addr->sin_port);
    return allowlist_matches(4, address, port);
  }

  if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *inet6_addr = (const struct sockaddr_in6 *)addr;
    if (inet_ntop(AF_INET6, &(inet6_addr->sin6_addr), address, sizeof(address)) == 0) {
      return 0;
    }
    port = (unsigned int)ntohs(inet6_addr->sin6_port);
    return allowlist_matches(6, address, port);
  }

  return 1;
}

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
  connect_fn real_connect = real_connect_fn();

  (void)addrlen;

  if (real_connect == 0) {
    errno = ENOSYS;
    return -1;
  }

  if (addr != 0 && (addr->sa_family == AF_INET || addr->sa_family == AF_INET6) && !inet_allowed(addr)) {
    errno = EACCES;
    return -1;
  }

  return real_connect(sockfd, addr, addrlen);
}
