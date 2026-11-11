# The push adapter's start: its FCM credential, the bank's service-account JSON key, becomes the file
# FCM_CREDENTIALS_FILE on the container's memory volume (/run/fcm, owned by the adapter's user only),
# mode 0400; the variable that carried it is dropped, then the adapter starts as the image starts it.
# A missing value stops it here, by name.
set -eu
: "${FCM_CREDENTIALS_FILE:?FCM_CREDENTIALS_FILE is required}"
# A restart keeps the memory volume, and a 0400 file can't be written over: replace it.
rm -f "$FCM_CREDENTIALS_FILE"
(umask 0377 && printf '%s' "${FCM_CREDENTIALS_JSON_BASE64:?FCM_CREDENTIALS_JSON_BASE64 is required}" | base64 -d > "$FCM_CREDENTIALS_FILE")
unset FCM_CREDENTIALS_JSON_BASE64
exec java org.springframework.boot.loader.launch.JarLauncher
