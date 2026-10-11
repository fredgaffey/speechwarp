/* Included before every eSpeak NG source by build-espeak.sh. The iOS SDK's <endian.h> lacks the leNNtoh family
   that eSpeak uses to read its data files; take them from OSByteOrder. */
#include <libkern/OSByteOrder.h>
#ifndef le16toh
#define le16toh(x) OSSwapLittleToHostInt16(x)
#define le32toh(x) OSSwapLittleToHostInt32(x)
#define le64toh(x) OSSwapLittleToHostInt64(x)
#define be16toh(x) OSSwapBigToHostInt16(x)
#define be32toh(x) OSSwapBigToHostInt32(x)
#define htole16(x) OSSwapHostToLittleInt16(x)
#define htole32(x) OSSwapHostToLittleInt32(x)
#endif
