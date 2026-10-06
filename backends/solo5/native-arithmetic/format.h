/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability. */
#ifndef FENRIR_NA_FORMAT_H
#define FENRIR_NA_FORMAT_H
#include "machine.h"
#include <stddef.h>
/* Canonical sample JSON. Returns bytes (not including NUL) or 0 on cap/shape error. */
size_t na_format_site(const struct na_sample *,char *,size_t);
size_t na_format_sample(const struct na_sample *,char *,size_t);
#endif
