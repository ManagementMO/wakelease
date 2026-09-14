#include "WakeLeaseProcess.h"
#include <errno.h>
#include <membership.h>
#include <stddef.h>
#include <sys/acl.h>
#include <uuid/uuid.h>

int wakelease_clear_directory_acl(int descriptor) {
    acl_t acl = acl_init(0);
    if (acl == NULL) return errno;
    int result = acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED);
    int failure = result == 0 ? 0 : (errno != 0 ? errno : EIO);
    acl_free(acl);
    return failure;
}

int wakelease_grant_removal(int descriptor, uid_t uid) {
    uuid_t identity;
    int result = mbr_uid_to_uuid(uid, identity);
    if (result != 0) return result;
    acl_t acl = acl_init(1);
    if (acl == NULL) return errno;
    acl_entry_t entry;
    acl_permset_t permissions;
    result = -1;
    if (acl_create_entry(&acl, &entry) == 0 &&
        acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 &&
        acl_set_qualifier(entry, identity) == 0 &&
        acl_get_permset(entry, &permissions) == 0 &&
        acl_clear_perms(permissions) == 0 &&
        acl_add_perm(permissions, ACL_READ_DATA) == 0 &&
        acl_add_perm(permissions, ACL_DELETE) == 0 &&
        acl_set_permset(entry, permissions) == 0 &&
        acl_valid(acl) == 0) {
        result = acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED);
    }
    int failure = result == 0 ? 0 : (errno != 0 ? errno : EIO);
    acl_free(acl);
    return failure;
}
