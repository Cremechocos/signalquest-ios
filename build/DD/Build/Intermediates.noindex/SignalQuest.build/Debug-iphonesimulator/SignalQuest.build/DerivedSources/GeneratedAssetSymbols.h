#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"fr.signalquest.ios";

/// The "AccentColor" asset catalog color resource.
static NSString * const ACColorNameAccentColor AC_SWIFT_PRIVATE = @"AccentColor";

/// The "BackgroundPrimary" asset catalog color resource.
static NSString * const ACColorNameBackgroundPrimary AC_SWIFT_PRIVATE = @"BackgroundPrimary";

/// The "BackgroundSecondary" asset catalog color resource.
static NSString * const ACColorNameBackgroundSecondary AC_SWIFT_PRIVATE = @"BackgroundSecondary";

/// The "BrandBlue" asset catalog color resource.
static NSString * const ACColorNameBrandBlue AC_SWIFT_PRIVATE = @"BrandBlue";

/// The "BrandGreen" asset catalog color resource.
static NSString * const ACColorNameBrandGreen AC_SWIFT_PRIVATE = @"BrandGreen";

/// The "BrandOrange" asset catalog color resource.
static NSString * const ACColorNameBrandOrange AC_SWIFT_PRIVATE = @"BrandOrange";

/// The "BrandPink" asset catalog color resource.
static NSString * const ACColorNameBrandPink AC_SWIFT_PRIVATE = @"BrandPink";

/// The "Danger" asset catalog color resource.
static NSString * const ACColorNameDanger AC_SWIFT_PRIVATE = @"Danger";

/// The "Fill" asset catalog color resource.
static NSString * const ACColorNameFill AC_SWIFT_PRIVATE = @"Fill";

/// The "Info" asset catalog color resource.
static NSString * const ACColorNameInfo AC_SWIFT_PRIVATE = @"Info";

/// The "LabelPrimary" asset catalog color resource.
static NSString * const ACColorNameLabelPrimary AC_SWIFT_PRIVATE = @"LabelPrimary";

/// The "LabelSecondary" asset catalog color resource.
static NSString * const ACColorNameLabelSecondary AC_SWIFT_PRIVATE = @"LabelSecondary";

/// The "LabelTertiary" asset catalog color resource.
static NSString * const ACColorNameLabelTertiary AC_SWIFT_PRIVATE = @"LabelTertiary";

/// The "Like" asset catalog color resource.
static NSString * const ACColorNameLike AC_SWIFT_PRIVATE = @"Like";

/// The "Separator" asset catalog color resource.
static NSString * const ACColorNameSeparator AC_SWIFT_PRIVATE = @"Separator";

/// The "Success" asset catalog color resource.
static NSString * const ACColorNameSuccess AC_SWIFT_PRIVATE = @"Success";

/// The "SurfaceElevated" asset catalog color resource.
static NSString * const ACColorNameSurfaceElevated AC_SWIFT_PRIVATE = @"SurfaceElevated";

/// The "SurfaceMuted" asset catalog color resource.
static NSString * const ACColorNameSurfaceMuted AC_SWIFT_PRIVATE = @"SurfaceMuted";

/// The "Warning" asset catalog color resource.
static NSString * const ACColorNameWarning AC_SWIFT_PRIVATE = @"Warning";

#undef AC_SWIFT_PRIVATE
