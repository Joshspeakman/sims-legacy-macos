// The launch window, laid out like the other ports' (Dungeon Siege, Diablo II, Delta Force): a banner (the game's logo
// over its art), the Resolution row, and a button for each group of settings (Display, Updates) that opens it as a
// panel. Choices are remembered in <data>/launcher.plist and passed to the game as SIMS_RESOLUTION, SIMS_WINDOWED,
// SIMS_NOTCH and SIMS_FPS (host/sims_mac.m, host/vk_metal.mm). The art is fetched at install time (tools/sims_art.py:
// the logo, character banner and background from the game's Steam store page) into <data>/art and a copy in the app;
// nothing from the game is stored in this project, and without the art the window writes the title.
#import <AppKit/AppKit.h>

// ---------------------------------------------------------------- settings
@interface DSRow : NSObject
@property NSString *title; @property NSArray<NSDictionary *> *choices; @property NSInteger index;
@property (copy) void (^activate)(void);     /* a row that runs something instead of cycling (Updates) */
@end
@implementation DSRow @end

/* The Sims' own interface: blue panels, white text, the plumbob's green for what is chosen */
static NSColor *accent(void) { return [NSColor colorWithSRGBRed:0.55 green:0.92 blue:0.38 alpha:1]; }
static NSColor *accent_dim(void) { return [NSColor colorWithSRGBRed:0.20 green:0.42 blue:0.85 alpha:1]; }
static NSColor *panel_blue(void) { return [NSColor colorWithSRGBRed:0.05 green:0.12 blue:0.42 alpha:0.88]; }
static NSColor *text_c(void) { return [NSColor colorWithSRGBRed:0.93 green:0.93 blue:0.88 alpha:1]; }
static NSColor *dim(void) { return [NSColor colorWithSRGBRed:0.66 green:0.66 blue:0.6 alpha:1]; }
static NSFont *din(CGFloat size)                    /* the system's rounded face, bold */
{
    NSFont *f = [NSFont systemFontOfSize:size weight:NSFontWeightBold];
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return d ? [NSFont fontWithDescriptor:d size:size] : f;
}
static NSFont *body(CGFloat size, BOOL bold)
{
    NSFont *f = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return d ? [NSFont fontWithDescriptor:d size:size] : f;
}

// ---------------------------------------------------------------- the view
/* A group's button opens it as a panel over the window, with Back where Quit was; Key Guide and Updates run their own. */
@interface DSSection : NSObject
@property NSString *title; @property NSArray<DSRow *> *rows;
@property (copy) void (^activate)(void); @property (copy) NSString *(^summary)(void);
@end
@implementation DSSection @end

@interface DSLaunchView : NSView
@property NSArray<DSRow *> *top; @property NSArray<DSSection *> *sections; @property NSInteger open;   /* the open group, -1 none */
@property NSInteger focus; @property NSInteger hover; @property NSInteger pressed;
@property NSImage *backdrop, *logo, *shot; @property NSString *note;
@property (copy) void (^onPlay)(void); @property (copy) void (^onQuit)(void); @property (copy) void (^onChange)(void);
@end

enum { HIT_NONE = -1, HIT_PLAY = 100, HIT_QUIT = 101, HIT_BACK = 102, HIT_SECTION = 200 };   /* rows: 10*row + 0 (left arrow) / 1 (value) / 2 (right arrow) */
enum { BANNER_H = 252, TOP_Y = 270 };

@implementation DSLaunchView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (NSArray<DSRow *> *)rows { return self.open >= 0 ? self.sections[self.open].rows : self.top; }
- (NSInteger)items { return (NSInteger)self.rows.count + (self.open >= 0 ? 0 : (NSInteger)self.sections.count); }   /* what the keyboard moves between */
- (NSRect)flyRect   /* an open group's panel: above Back and Play */
{
    NSRect b = self.bounds; CGFloat h = b.size.height - 268, need = 80 + 74 * (CGFloat)(self.open >= 0 ? self.sections[self.open].rows.count : 0);
    CGFloat grow = MIN(MAX(need - h, 0), 60);
    return NSMakeRect(40, 168 - grow, b.size.width - 80, h + grow);
}
- (NSRect)rowRect:(NSInteger)k { CGFloat y = self.open >= 0 ? self.flyRect.origin.y + 70 : TOP_Y + 14; return NSMakeRect(70, y + 74 * k, self.bounds.size.width - 140, 64); }
- (NSRect)arrow:(NSInteger)k right:(BOOL)right { NSRect r = [self rowRect:k]; return NSMakeRect(right ? NSMaxX(r) - 34 : NSMaxX(r) - 330, r.origin.y + 6, 30, 30); }
- (NSRect)valueRect:(NSInteger)k { NSRect r = [self rowRect:k]; return NSMakeRect(NSMaxX(r) - 300, r.origin.y + 7, 262, 30); }
- (NSRect)sectionRect:(NSInteger)i
{
    NSInteger n = (NSInteger)self.sections.count, per = 2, line = i / per, inLine = MIN(per, n - line * per), col = i % per;
    CGFloat w = 290, g = 28, x0 = (self.bounds.size.width - (inLine * w + (inLine - 1) * g)) / 2;
    return NSMakeRect(x0 + col * (w + g), TOP_Y + 74 * self.top.count + 44 + line * 100, w, 54);
}
- (NSRect)playRect { NSRect b = self.bounds; return NSMakeRect(NSMidX(b) + 12, b.size.height - 80, 220, 52); }
- (NSRect)quitRect { NSRect b = self.bounds; return NSMakeRect(NSMidX(b) - 232, b.size.height - 80, 220, 52); }
- (NSInteger)hit:(NSPoint)p
{
    if (NSPointInRect(p, self.playRect)) return HIT_PLAY;
    if (NSPointInRect(p, self.quitRect)) return self.open >= 0 ? HIT_BACK : HIT_QUIT;
    if (self.open < 0) for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) if (NSPointInRect(p, [self sectionRect:i])) return HIT_SECTION + i;
    for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
        if (NSPointInRect(p, [self arrow:k right:NO])) return 10 * k;
        if (NSPointInRect(p, [self arrow:k right:YES])) return 10 * k + 2;
        if (NSPointInRect(p, [self valueRect:k])) return 10 * k + 1;
    }
    if (self.open >= 0 && !NSPointInRect(p, self.flyRect)) return HIT_BACK;   /* a click outside the panel closes it */
    return HIT_NONE;
}
- (void)openSection:(NSInteger)i
{
    DSSection *s = self.sections[i]; self.focus = (NSInteger)self.top.count + i;
    if (s.activate) { s.activate(); self.needsDisplay = YES; return; }
    self.open = i; self.focus = 0; self.hover = HIT_NONE; self.needsDisplay = YES;
}
- (void)closeSection { if (self.open < 0) return; self.focus = (NSInteger)self.top.count + self.open; self.open = -1; self.hover = HIT_NONE; self.needsDisplay = YES; }
- (void)updateTrackingAreas
{
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e { NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseDown:(NSEvent *)e { self.pressed = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent *)e
{
    NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]], p = self.pressed; self.pressed = HIT_NONE; self.needsDisplay = YES;
    if (h != p || h == HIT_NONE) return;
    if (h == HIT_PLAY) { if (self.onPlay) self.onPlay(); return; }
    if (h == HIT_QUIT) { if (self.onQuit) self.onQuit(); return; }
    if (h == HIT_BACK) { [self closeSection]; return; }
    if (h >= HIT_SECTION) { [self openSection:h - HIT_SECTION]; return; }
    NSInteger k = h / 10; self.focus = k;
    if (self.rows[k].activate) { self.rows[k].activate(); self.needsDisplay = YES; return; }
    [self step:k by:(h % 10 == 0) ? -1 : 1];
}
- (void)step:(NSInteger)k by:(NSInteger)dir
{
    if (k >= (NSInteger)self.rows.count) { NSInteger n = [self items]; self.focus = (self.focus + dir + n) % n; self.needsDisplay = YES; return; }   /* the group buttons */
    DSRow *r = self.rows[k]; NSInteger n = (NSInteger)r.choices.count;
    if (r.activate) { r.activate(); self.needsDisplay = YES; return; }
    r.index = (r.index + dir + n) % n; self.needsDisplay = YES;
    if (self.onChange) self.onChange();
}
- (void)keyDown:(NSEvent *)e
{
    NSInteger n = [self items], rc = (NSInteger)self.rows.count;
    switch (e.keyCode) {
    case 0x24: case 0x4c:                                                /* Return, Enter */
        if (self.focus >= rc) { [self openSection:self.focus - rc]; return; }
        if (self.rows[self.focus].activate) { self.rows[self.focus].activate(); self.needsDisplay = YES; return; }
        if (self.open >= 0) { [self closeSection]; return; }
        if (self.onPlay) self.onPlay(); return;
    case 0x35: if (self.open >= 0) { [self closeSection]; return; }      /* Escape */
               if (self.onQuit) self.onQuit(); return;
    case 0x7e: self.focus = (self.focus + n - 1) % n; self.needsDisplay = YES; return;
    case 0x7d: self.focus = (self.focus + 1) % n; self.needsDisplay = YES; return;
    case 0x7b: [self step:self.focus by:-1]; return;
    case 0x7c: [self step:self.focus by:1]; return;
    }
    [super keyDown:e];
}
static void draw_text(NSString *s, NSFont *f, NSColor *c, NSRect r, NSTextAlignment al, NSShadow *sh, CGFloat kern)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = al; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *a = [@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps, NSKernAttributeName: @(kern)} mutableCopy];
    if (sh) a[NSShadowAttributeName] = sh;
    [s drawInRect:r withAttributes:a];
}
/* (the other ports frame panels with corner marks; The Sims' are plain rounded rectangles) */
static void brackets(NSRect r, CGFloat len, CGFloat w, NSColor *c) { (void)r; (void)len; (void)w; (void)c; }
static void fill_over(NSRect r) { NSRectFillUsingOperation(r, NSCompositingOperationSourceOver); }
- (void)drawButton:(NSRect)r title:(NSString *)title code:(NSInteger)code primary:(BOOL)primary
{
    BOOL hot = self.hover == code, down = self.pressed == code;
    NSColor *fill = down ? [accent() colorWithAlphaComponent:0.55] : hot ? [accent_dim() colorWithAlphaComponent:0.95] : primary ? [NSColor colorWithSRGBRed:0.22 green:0.62 blue:0.22 alpha:0.95] : panel_blue();
    [fill setFill]; [[NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.height / 2 yRadius:r.size.height / 2] fill];
    [[NSColor colorWithWhite:1 alpha:primary || hot ? 0.95 : 0.6] setStroke]; NSBezierPath *b = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:r.size.height / 2 - 1 yRadius:r.size.height / 2 - 1]; b.lineWidth = 2; [b stroke];
    brackets(NSInsetRect(r, -4, -4), 10, 2, primary || hot ? accent() : accent_dim());
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowOffset = NSMakeSize(0, -1.5); sh.shadowBlurRadius = 2;
    NSFont *f = din(primary ? 30 : 26); NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: hot || primary ? NSColor.whiteColor : text_c(), NSShadowAttributeName: sh, NSKernAttributeName: @4};
    NSSize sz = [title sizeWithAttributes:at];   /* the capitals centred on the button */
    [title drawAtPoint:NSMakePoint(NSMidX(r) - sz.width / 2, round(NSMidY(r) + f.capHeight / 2 - f.ascender)) withAttributes:at];
}
- (void)drawArrow:(NSRect)r right:(BOOL)right lit:(BOOL)lit
{
    NSBezierPath *p = [NSBezierPath bezierPath]; CGFloat x0 = r.origin.x + 9, x1 = NSMaxX(r) - 9, y0 = r.origin.y + 7, y1 = NSMaxY(r) - 7, ym = NSMidY(r);
    if (right) { [p moveToPoint:NSMakePoint(x0, y0)]; [p lineToPoint:NSMakePoint(x1, ym)]; [p lineToPoint:NSMakePoint(x0, y1)]; }
    else { [p moveToPoint:NSMakePoint(x1, y0)]; [p lineToPoint:NSMakePoint(x0, ym)]; [p lineToPoint:NSMakePoint(x1, y1)]; }
    [p closePath]; [(lit ? NSColor.whiteColor : accent()) setFill]; [p fill];
}
- (void)drawRows:(NSShadow *)sh
{
    for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
        DSRow *row = self.rows[k]; NSRect r = [self rowRect:k]; NSDictionary *ch = row.choices[row.index];
        if (k == self.focus) { [[NSColor colorWithWhite:1 alpha:0.08] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -10, -2) xRadius:10 yRadius:10] fill]; }
        draw_text(row.title, din(22), NSColor.whiteColor, NSMakeRect(r.origin.x + 4, r.origin.y + 10, 300, 30), NSTextAlignmentLeft, sh, 2);
        [self drawArrow:[self arrow:k right:NO] right:NO lit:self.hover == 10 * k];
        [self drawArrow:[self arrow:k right:YES] right:YES lit:self.hover == 10 * k + 2];
        draw_text(ch[@"label"], body(20, YES), self.hover == 10 * k + 1 ? NSColor.whiteColor : text_c(), [self valueRect:k], NSTextAlignmentCenter, sh, 0.5);
        draw_text(ch[@"note"] ?: @"", body(12.5, NO), dim(), NSMakeRect(NSMaxX(r) - 340, r.origin.y + 40, 350, 18), NSTextAlignmentCenter, nil, 0);
        if (k + 1 < (NSInteger)self.rows.count) { [[accent_dim() colorWithAlphaComponent:0.35] setFill]; fill_over(NSMakeRect(r.origin.x, NSMaxY(r) + 5, r.size.width, 1)); }
    }
}
- (void)drawPanel:(NSRect)panel
{
    [panel_blue() setFill]; [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:14 yRadius:14] fill];
    [[NSColor colorWithWhite:1 alpha:0.5] setStroke]; NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(panel, 1, 1) xRadius:13 yRadius:13]; bp.lineWidth = 2; [bp stroke];
    brackets(NSInsetRect(panel, -5, -5), 18, 2.5, accent());
}
/* an image filling a rectangle, its aspect kept (cropped), at the given share of its own centre */
static void draw_cover(NSImage *img, NSRect r, CGFloat fraction)
{
    NSSize is = img.size; CGFloat sc = MAX(r.size.width / is.width, r.size.height / is.height), w = r.size.width / sc, h = r.size.height / sc;
    [img drawInRect:r fromRect:NSMakeRect((is.width - w) / 2, (is.height - h) / 2, w, h) operation:NSCompositingOperationSourceOver fraction:fraction
     respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}
- (void)drawBanner:(NSRect)br shadow:(NSShadow *)sh
{
    [NSColor.blackColor setFill]; NSRectFill(br);
    if (self.backdrop) draw_cover(self.backdrop, br, 1);
    if (self.shot) {   /* the screenshot on the right, fading into the background towards the logo */
        NSRect sr = NSMakeRect(br.size.width * 0.38, 0, br.size.width * 0.62, br.size.height);
        NSImage *layer = [NSImage imageWithSize:sr.size flipped:YES drawingHandler:^BOOL(NSRect dst) {
            draw_cover(self.shot, dst, 1);
            NSGradient *fade = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0 alpha:1], 0.0, [NSColor colorWithWhite:0 alpha:0.6], 0.25, [NSColor colorWithWhite:0 alpha:0], 0.55, nil];
            [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationDestinationOut];
            [fade drawInRect:dst angle:0];
            return YES;
        }];
        [layer drawInRect:sr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    NSGradient *shade = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0 alpha:0.45], 0.0, [NSColor colorWithWhite:0 alpha:0.05], 0.5, [NSColor colorWithWhite:0 alpha:0.15], 1.0, nil];
    [shade drawInRect:br angle:0];
    /* the logo on the left, the subtitle under it */
    NSRect lr = NSMakeRect(28, 16, 300, 186);
    if (self.logo) {
        CGFloat h = lr.size.height, w = h * self.logo.size.width / self.logo.size.height; if (w > lr.size.width) { w = lr.size.width; h = w * self.logo.size.height / self.logo.size.width; }
        NSShadow *glow = [NSShadow new]; glow.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; glow.shadowOffset = NSZeroSize; glow.shadowBlurRadius = 14;
        [NSGraphicsContext saveGraphicsState]; [glow set];
        [self.logo drawInRect:NSMakeRect(NSMidX(lr) - w / 2, lr.origin.y + (lr.size.height - h) / 2, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
    }
    else draw_text(@"THE SIMS", din(54), NSColor.whiteColor, NSMakeRect(lr.origin.x - 20, 70, lr.size.width + 40, 64), NSTextAlignmentCenter, sh, 6);
    draw_text(@"NATIVE EDITION FOR macOS", din(15), NSColor.whiteColor, NSMakeRect(lr.origin.x - 20, NSMaxY(lr) + 8, lr.size.width + 40, 22), NSTextAlignmentCenter, sh, 4);
    NSGradient *fade = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:0] endingColor:[NSColor colorWithWhite:0 alpha:0.85]];
    [fade drawInRect:NSMakeRect(0, BANNER_H - 36, br.size.width, 36) angle:90];
    [accent_dim() setFill]; NSRectFill(NSMakeRect(0, BANNER_H, br.size.width, 1.5));
}
- (void)drawRect:(NSRect)dirty
{
    NSRect b = self.bounds;
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowOffset = NSMakeSize(0, -1); sh.shadowBlurRadius = 3;
    [[NSColor colorWithWhite:0.04 alpha:1] setFill]; NSRectFill(b);
    if (self.backdrop) draw_cover(self.backdrop, b, 0.55);              /* the game's texture, darker below the banner */
    NSGradient *vig = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0 alpha:0.25], 0.0, [NSColor colorWithWhite:0 alpha:0.75], 1.0, nil];
    [vig drawInRect:b relativeCenterPosition:NSMakePoint(0, -0.1)];
    [self drawBanner:NSMakeRect(0, 0, b.size.width, BANNER_H) shadow:sh];
    /* the top level: the Controls row, then a button for each group with a summary under it */
    NSInteger fly = self.open, foc = self.focus, hov = self.hover; self.open = -1;
    if (fly >= 0) self.focus = self.hover = HIT_NONE;           /* under the panel: nothing lit */
    [self drawPanel:NSMakeRect(54, TOP_Y, b.size.width - 108, 74 * self.top.count + 14)];
    [self drawRows:sh];
    for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) {
        DSSection *s = self.sections[i]; NSRect r = [self sectionRect:i]; NSInteger code = HIT_SECTION + i;
        if (fly < 0 && self.focus == (NSInteger)self.top.count + i) { [[accent() colorWithAlphaComponent:0.35] setFill]; NSRect g = NSInsetRect(r, -6, -6); [[NSBezierPath bezierPathWithRoundedRect:g xRadius:g.size.height / 2 yRadius:g.size.height / 2] fill]; }
        [self drawButton:r title:s.title.uppercaseString code:code primary:NO];
        NSString *sum = s.summary ? s.summary() : nil;
        if (!sum) { NSMutableArray *l = [NSMutableArray array]; for (DSRow *row in s.rows) [l addObject:row.choices[row.index][@"label"]]; sum = [l componentsJoinedByString:@" · "]; }
        draw_text(sum, body(12.5, NO), dim(), NSMakeRect(r.origin.x - 10, NSMaxY(r) + 8, r.size.width + 20, 32), NSTextAlignmentCenter, sh, 0);
    }
    if (self.note.length) draw_text(self.note, body(12.5, NO), dim(), NSMakeRect(54, [self sectionRect:(NSInteger)self.sections.count - 1].origin.y + 98, b.size.width - 108, 34), NSTextAlignmentCenter, sh, 0);
    self.open = fly; self.focus = foc; self.hover = hov;
    /* an open group: a panel over the window */
    if (self.open >= 0) {
        [[NSColor colorWithWhite:0 alpha:0.6] setFill]; fill_over(b);
        NSRect f = self.flyRect;
        [[NSColor colorWithSRGBRed:0.04 green:0.09 blue:0.32 alpha:1] setFill]; [[NSBezierPath bezierPathWithRoundedRect:f xRadius:18 yRadius:18] fill];
        [[NSColor colorWithWhite:1 alpha:0.55] setStroke]; NSBezierPath *fp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(f, 1, 1) xRadius:17 yRadius:17]; fp.lineWidth = 2; [fp stroke];
        brackets(NSInsetRect(f, -5, -5), 22, 3, accent());
        draw_text(self.sections[self.open].title, din(28), NSColor.whiteColor, NSMakeRect(f.origin.x, f.origin.y + 20, f.size.width, 36), NSTextAlignmentCenter, sh, 5);
        [[accent_dim() colorWithAlphaComponent:0.6] setFill]; fill_over(NSMakeRect(f.origin.x + 30, f.origin.y + 60, f.size.width - 60, 1));
        [self drawRows:sh];
    }
    [self drawButton:self.quitRect title:self.open >= 0 ? @"BACK" : @"QUIT" code:self.open >= 0 ? HIT_BACK : HIT_QUIT primary:NO];
    [self drawButton:self.playRect title:@"PLAY" code:HIT_PLAY primary:YES];
}
@end

// ---------------------------------------------------------------- choices, settings file, the window
static NSInteger index_of(NSArray<NSDictionary *> *c, NSString *v, NSInteger dflt)
{
    for (NSUInteger k = 0; k < c.count; k++) if ([c[k][@"value"] isEqualToString:v ?: @""]) return (NSInteger)k;
    return dflt;
}
/* the screens the game can be given: the display's own pixels (Retina) or its points, both drawn the same size (the
 * game scales its art and interface to the screen's height), Retina the sharper */
static NSArray<NSDictionary *> *resolution_choices(void)
{
    NSScreen *s = NSScreen.mainScreen; NSSize p = s.frame.size; CGFloat k = s.backingScaleFactor > 1 ? s.backingScaleFactor : 1;
    NSMutableArray *a = [NSMutableArray array];
    if (k > 1) [a addObject:@{@"value": @"retina", @"label": [NSString stringWithFormat:@"Retina (%d × %d)", (int)(p.width * k), (int)(p.height * k)],
                               @"note": @"Every pixel of the display: the sharpest picture"}];
    [a addObject:@{@"value": @"display", @"label": [NSString stringWithFormat:@"Standard (%d × %d)", (int)p.width, (int)p.height],
                   @"note": k > 1 ? @"Half the pixels each way, scaled up: lighter on the GPU" : @"The display's own size"}];
    return a;
}
static NSArray<NSDictionary *> *shape_choices(void)
{
    return @[@{@"value": @"wide", @"label": @"Widescreen", @"note": @"The Legacy Collection's wide view: more of the lot"},
             @{@"value": @"4:3", @"label": @"Original 4:3", @"note": @"Bars at the sides, as the game first shipped"}];
}
static NSArray<NSDictionary *> *window_choices(void)
{
    return @[@{@"value": @"full", @"label": @"Full Screen", @"note": @"The whole display, Dock and menu bar hidden"},
             @{@"value": @"window", @"label": @"Window", @"note": @"A window you can move and resize; the game keeps its shape"}];
}
static BOOL has_notch(void) { if (@available(macOS 12.0, *)) return NSScreen.mainScreen.safeAreaInsets.top > 0; return NO; }
static NSArray<NSDictionary *> *notch_choices(void)
{
    return @[@{@"value": @"below", @"label": @"Below the Notch", @"note": @"The picture starts under the camera; nothing hidden"},
             @{@"value": @"full", @"label": @"Whole Display", @"note": @"Taller picture; the notch covers a little of the top"}];
}
static NSArray<NSDictionary *> *framerate_choices(void)
{
    NSInteger hz = NSScreen.mainScreen.maximumFramesPerSecond; if (hz <= 0) hz = 60;
    NSMutableArray *a = [NSMutableArray arrayWithObject:@{@"value": @"display", @"label": [NSString stringWithFormat:@"Display (%ld FPS)", (long)hz],
        @"note": @"As smooth as the display shows"}];
    if (hz > 60) [a addObject:@{@"value": @"60", @"label": @"60 FPS", @"note": @"Capped at 60: cooler and quieter, longer on battery"}];
    [a addObject:@{@"value": @"30", @"label": @"30 FPS", @"note": @"Lightest: for long sessions on battery"}];
    return a;
}

// ---------------------------------------------------------------- the game's own resolution setting (Options.iff)
/* The game keeps its screen as a label, "1920x1200 (14:9)" or "1024x768 (4:3)", the last string of the Optn chunk of
 * UserData/Options.iff (Options > Graphics > Resolution); it reads it at start-up, and only its shape matters here (the
 * picture is drawn at the size of the window). A fresh data folder, or an Options.iff from before the Legacy Collection's
 * display settings, has none: the game then takes SIMS_GAME_RES (runtime/win32/hooks.c). The file is never created
 * here (the game copies its template town only into an empty UserData), only edited: the string replaced and the
 * length change taken from the filler chunk (XXXX) after it, so no other chunk moves. */
static NSString *options_path(NSString *data)
{
    return [data stringByAppendingPathComponent:@"drive_c/Users/player/Saved Games/Electronic Arts/The Sims 25/UserData/Options.iff"];
}
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0]; }
/* the resolution string's place in the file: [*s, *e) without its NUL, the Optn chunk at *o; NO for a file without it,
 * or one laid out other than the game writes it: the header's pointer (offset 60) to a resource map (rsmp) that lists
 * Optn alone, at 64 */
static BOOL options_find(NSData *f, size_t *o, size_t *s, size_t *e)
{
    const uint8_t *d = f.bytes; size_t n = f.length, k = 64;
    if (n < 64 + 90 || memcmp(d + k, "Optn", 4)) return NO;
    size_t end = k + be32(d + k + 4);
    if (end > n || end < k + 90 || memcmp(d + k + 84, "ntpO", 4) || d[k + 88] < 8) return NO;   /* version 8 and later */
    size_t z = end - 1;                                               /* the chunk is padded to an even size: "(4:3)\0o", or "\0\0" here */
    if (d[z]) { if (d[z - 1]) return NO; z--; } else if (!d[z - 1]) z--;
    size_t st = z; while (st > k + 89 && d[st - 1]) st--;
    int w, h; char buf[64]; size_t l = z - st; if (l == 0 || l >= sizeof buf) return NO;
    memcpy(buf, d + st, l); buf[l] = 0; if (sscanf(buf, "%dx%d", &w, &h) != 2) return NO;
    size_t r = be32(d + 60);                                          /* the map: reserved, version, "pmsr", size, 1 type ("ntpO", 1 entry at 64) */
    if (r < end || r + 76 + 32 > n || memcmp(d + r, "rsmp", 4)) return NO;
    const uint8_t *m = d + r + 76;
    if (memcmp(m + 8, "pmsr", 4) || le32(m + 16) != 1 || memcmp(m + 20, "ntpO", 4) || le32(m + 24) != 1 || le32(m + 28) != 64) return NO;
    *o = k; *s = st; *e = z; return YES;
}
static NSString *options_resolution(NSString *data)
{
    NSData *f = [NSData dataWithContentsOfFile:options_path(data)]; size_t o, s, e;
    if (!f || !options_find(f, &o, &s, &e)) return nil;
    return [[NSString alloc] initWithBytes:(const uint8_t *)f.bytes + s length:e - s encoding:NSASCIIStringEncoding];
}
/* the string replaced (NUL, and a pad byte to keep the chunk even, as the game writes it); the chunks after it move,
 * so the header's pointer to the map moves with them (the map's one entry, Optn at 64, stays) */
static BOOL options_set_resolution(NSString *data, NSString *res)
{
    NSString *p = options_path(data); NSData *f = [NSData dataWithContentsOfFile:p]; size_t o, s, e;
    if (!f || !options_find(f, &o, &s, &e)) return NO;
    const uint8_t *d = f.bytes; NSData *r = [res dataUsingEncoding:NSASCIIStringEncoding]; if (!r || r.length > 60) return NO;
    size_t x = o + be32(d + o + 4), pad = (s - o + r.length + 1) & 1;
    long delta = (long)(r.length + 1 + pad) - (long)(x - s);
    NSMutableData *m = [NSMutableData dataWithBytes:d length:s];
    [m appendData:r]; [m appendBytes:"\0\0" length:1 + pad];
    [m appendBytes:d + x length:f.length - x];
    uint32_t ol = be32(d + o + 4) + (uint32_t)delta, rp = be32(d + 60) + (uint32_t)delta;
    uint8_t c[4] = {ol >> 24, ol >> 16, ol >> 8, ol}, q[4] = {rp >> 24, rp >> 16, rp >> 8, rp};
    [m replaceBytesInRange:NSMakeRange(o + 4, 4) withBytes:c]; [m replaceBytesInRange:NSMakeRange(60, 4) withBytes:q];
    size_t o2, s2, e2; if (!options_find(m, &o2, &s2, &e2) || e2 - s2 != r.length) return NO;   /* reads back as the game will */
    return [m writeToFile:p atomically:YES];
}
static BOOL wide_label(NSString *r) { return r && ![r containsString:@"(4:3)"]; }
/* the label for the game's screen, as its own list writes them */
static NSString *game_label(int w, int h, BOOL wide) { return wide ? [NSString stringWithFormat:@"%dx%d (14:9)", w, h] : [NSString stringWithFormat:@"%dx%d (4:3)", h * 4 / 3, h]; }

/* the chosen settings as environment for the game (host/sims_mac.m, host/vk_metal.mm, runtime/win32/hooks.c). An
 * environment already set (a terminal) wins. */
static void apply(NSString *res, NSString *shape, NSString *window, NSString *notch, NSString *fps)
{
    if (!getenv("SIMS_RESOLUTION")) setenv("SIMS_RESOLUTION", res.UTF8String, 1);
    if (!getenv("SIMS_WINDOWED") && [window isEqualToString:@"window"]) setenv("SIMS_WINDOWED", "1", 1);
    if (!getenv("SIMS_NOTCH") && [notch isEqualToString:@"below"]) setenv("SIMS_NOTCH", "below", 1);
    if (!getenv("SIMS_FPS") && ![fps isEqualToString:@"display"]) setenv("SIMS_FPS", fps.UTF8String, 1);
    if (!getenv("SIMS_GAME_RES")) {                    /* the label: the size the host will give the game */
        NSScreen *s = NSScreen.mainScreen; CGFloat k = [res isEqualToString:@"retina"] && s.backingScaleFactor > 1 ? s.backingScaleFactor : 1;
        CGFloat top = 0; if (@available(macOS 12.0, *)) if ([notch isEqualToString:@"below"] && ![window isEqualToString:@"window"]) top = s.safeAreaInsets.top;
        setenv("SIMS_GAME_RES", game_label((int)(s.frame.size.width * k) & ~1, (int)((s.frame.size.height - top) * k) & ~1, [shape isEqualToString:@"wide"]).UTF8String, 1);
    }
}
/* the art: <data>/art, else the copy in the app (Resources/art) */
static NSImage *art(NSString *data, NSString *name)
{
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:[data stringByAppendingPathComponent:@"art"]];
    if (NSBundle.mainBundle.resourcePath) [dirs addObject:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"art"]];
    for (NSString *d in dirs) for (NSString *ext in @[@"png", @"jpg"]) {
        NSImage *i = [[NSImage alloc] initWithContentsOfFile:[[d stringByAppendingPathComponent:name] stringByAppendingPathExtension:ext]];
        if (i.size.width > 16) return i;
    }
    return nil;
}
/* the part of an image with any opacity (Steam's logos come with empty margins), its bottom `cut` share left off */
static NSImage *trimmed(NSImage *img, CGFloat cut)
{
    CGImageRef c = [img CGImageForProposedRect:NULL context:nil hints:nil]; if (!c) return img;
    size_t w = CGImageGetWidth(c), h = CGImageGetHeight(c); uint8_t *px = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB(); CGContextRef g = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(g, CGRectMake(0, 0, w, h), c);
    size_t x0 = w, y0 = h, x1 = 0, y1 = 0;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) if (px[(y * w + x) * 4 + 3] > 8) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    CGContextRelease(g); CGColorSpaceRelease(cs); free(px);
    if (x1 < x0) return img;
    CGImageRef t = CGImageCreateWithImageInRect(c, CGRectMake(x0, y0, x1 - x0 + 1, (y1 - y0 + 1) * (1 - cut)));   /* bitmap rows run top-down here */
    NSImage *r = [[NSImage alloc] initWithCGImage:t size:NSZeroSize]; CGImageRelease(t);
    return cut > 0 ? trimmed(r, 0) : r;
}


@interface DSBlockTarget : NSObject      /* a button action as a block */
@property (copy) void (^fire)(NSInteger tag);
- (void)clicked:(NSButton *)b;
@end
@implementation DSBlockTarget
- (void)clicked:(NSButton *)b { if (self.fire) self.fire(b.tag); }
@end

// ---------------------------------------------------------------- updates
/* install.sh gives each app an updater (Contents/MacOS/update, passed in DS_UPDATER): it fetches the branch the app
 * follows (main, or nightly for Nightly) from GitHub into a worktree of the checkout the app was installed from and
 * rebuilds the app from it, keeping the game folder, saves and settings. The launcher asks GitHub (in the
 * background, each time it opens) whether that branch moved past the commit the app was built from. */
enum { UPD_NONE, UPD_CHECKING, UPD_CURRENT, UPD_AVAILABLE, UPD_ERROR };
static void on_main(dispatch_block_t b) { CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, b); CFRunLoopWakeUp(CFRunLoopGetMain()); }
static NSString *short_commit(NSString *c) { return c.length > 7 ? [c substringToIndex:7] : (c ?: @""); }
static NSString *update_check(NSString *updater)   /* the newest commit of the branch on GitHub; nil if it can't be reached */
{
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater, @"--check"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ if (t.running) [t terminate]; });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    NSString *out = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return t.terminationStatus == 0 && out.length >= 40 ? [out substringToIndex:40] : nil;
}
static NSArray<NSDictionary *> *update_choice(int state, NSString *branch, NSString *built, NSString *latest)
{
    NSString *label = @"Not available", *note = @"This copy wasn't installed from the GitHub repository";
    switch (state) {
    case UPD_CHECKING: label = @"Checking..."; note = [NSString stringWithFormat:@"Asking GitHub for the newest %@", branch]; break;
    case UPD_CURRENT: label = @"Up to date"; note = [NSString stringWithFormat:@"%@ %@", branch, short_commit(built)]; break;
    case UPD_AVAILABLE: label = @"Update available"; note = [NSString stringWithFormat:@"%@ -> %@: press to install", short_commit(built), short_commit(latest)]; break;
    case UPD_ERROR: label = @"Couldn't check"; note = @"GitHub unreachable or not signed in: press to retry"; break;
    }
    return @[@{@"value": @"", @"label": label, @"note": note}];
}
/* the phase of install.sh's output, in words */
static NSString *update_phase(NSString *line, NSString *branch)
{
    if ([line hasPrefix:@"== fetching"]) return @"Downloading the update from GitHub";
    if ([line hasPrefix:[NSString stringWithFormat:@"== %@:", branch]]) return [@"Got " stringByAppendingString:[line substringFromIndex:branch.length + 4]];
    if ([line hasPrefix:@"== analysis"]) return @"Rebuilding from your game: analysing its code (1 of 4)";
    if ([line hasPrefix:@"== lifting"]) return @"Rebuilding from your game: translating to native code (2 of 4)";
    if ([line hasPrefix:@"== compiling"]) return @"Rebuilding from your game: compiling (3 of 4)";
    if ([line hasPrefix:@"== installing"]) return @"Installing the new app (4 of 4)";
    return nil;
}
/* runs the updater with a progress window (modal); returns YES when the app was rebuilt */
static BOOL update_run(NSWindow *parent, NSString *updater, NSString *branch, NSString *logPath)
{
    NSPanel *pn = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 170) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    pn.title = @"Updating";
    NSTextField *title = [NSTextField labelWithString:@"Updating to the newest version"]; title.font = [NSFont boldSystemFontOfSize:14]; title.frame = NSMakeRect(20, 128, 480, 22);
    NSTextField *status = [NSTextField wrappingLabelWithString:@"Starting..."]; status.frame = NSMakeRect(20, 64, 480, 56);
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 44, 480, 12)]; spin.indeterminate = YES; [spin startAnimation:nil];
    NSTextField *time = [NSTextField labelWithString:@"This takes a few minutes. Your saves and settings are kept."]; time.font = [NSFont systemFontOfSize:11]; time.textColor = NSColor.secondaryLabelColor; time.frame = NSMakeRect(20, 14, 360, 18);
    NSButton *btn = [NSButton buttonWithTitle:@"Close" target:nil action:nil]; btn.frame = NSMakeRect(400, 8, 100, 30); btn.hidden = YES;
    for (NSView *x in @[title, status, spin, time, btn]) [pn.contentView addSubview:x];
    if (parent) [pn setFrameOrigin:NSMakePoint(NSMidX(parent.frame) - 260, NSMidY(parent.frame) - 85)]; else [pn center];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater];
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe; t.standardError = pipe;
    NSMutableString *pending = [NSMutableString new], *tail = [NSMutableString new];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData; if (!d.length) return;
        [log writeData:d];
        NSString *chunk = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (pending) {
            [pending appendString:chunk];
            NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [pending substringToIndex:nl.location]; [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                [tail appendFormat:@"%@\n", line]; if (tail.length > 600) [tail deleteCharactersInRange:NSMakeRange(0, tail.length - 600)];
                NSString *ph = update_phase(line, branch);
                if (ph) on_main(^{ status.stringValue = ph; });
            }
        }
    };
    __block BOOL ok = NO;
    __attribute__((objc_precise_lifetime)) DSBlockTarget *bt = [DSBlockTarget new];   /* a button's target is weak: kept here */
    bt.fire = ^(NSInteger tag) { (void)tag; [NSApp stopModal]; };
    btn.target = bt; btn.action = @selector(clicked:);
    t.terminationHandler = ^(NSTask *task) {
        int code = task.terminationStatus;
        on_main(^{
            pipe.fileHandleForReading.readabilityHandler = nil; [log closeFile];
            [spin stopAnimation:nil]; spin.hidden = YES; btn.hidden = NO;
            if (code == 0) { ok = YES; title.stringValue = @"Updated"; status.stringValue = @"The new version is installed. The app restarts when you press Restart."; btn.title = @"Restart"; }
            else {
                NSString *last; @synchronized (pending) { last = [[tail componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "]; }
                title.stringValue = @"The update didn't finish";
                status.stringValue = [NSString stringWithFormat:@"Nothing was changed if it stopped before installing. Details: %@  (%@)", logPath,
                                      last.length > 160 ? [last substringFromIndex:last.length - 160] : last];
                time.stringValue = @"";
            }
        });
    };
    if (![t launchAndReturnError:nil]) { [log closeFile]; return NO; }
    [pn makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:pn];
    [pn orderOut:nil];
    return ok;
}

/* Shows the launch window (modal) unless DS_NO_LAUNCHER is set; returns 0 to quit. DS_LAUNCHER_SHOT=<png> renders it
 * to an image instead (development; DS_LAUNCHER_OPEN=<group> renders that group's panel open). */
int ds_launcher_run(const char *game_dir, const char *data_dir)
{
    NSString *data = @(data_dir), *plistPath = [data stringByAppendingPathComponent:@"launcher.plist"]; (void)game_dir;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:plistPath] ?: @{};
    DSRow *res = [DSRow new], *shape = [DSRow new], *window = [DSRow new], *notch = [DSRow new], *fps = [DSRow new];
    res.title = @"Resolution"; res.choices = resolution_choices(); res.index = index_of(res.choices, saved[@"resolution"], 0);
    NSString *gameRes = options_resolution(data);      /* the game's own setting, if it has one: a change made in the game wins */
    NSString *shapeNow = gameRes ? (wide_label(gameRes) ? @"wide" : @"4:3") : saved[@"shape"];
    shape.title = @"Screen Shape"; shape.choices = shape_choices(); shape.index = index_of(shape.choices, shapeNow, 0);
    window.title = @"Window"; window.choices = window_choices(); window.index = index_of(window.choices, saved[@"window"], 0);
    notch.title = @"Notch"; notch.choices = notch_choices(); notch.index = index_of(notch.choices, saved[@"notch"], 0);
    fps.title = @"Frame Rate"; fps.choices = framerate_choices(); fps.index = index_of(fps.choices, saved[@"frameRate"], 0);
    NSString *(^val)(DSRow *) = ^NSString *(DSRow *r) { return r.choices[r.index][@"value"]; };
    void (^finish)(void) = ^{                          /* the choices: saved, given to the game, and its own setting matched */
        [@{@"resolution": val(res), @"shape": val(shape), @"window": val(window), @"notch": val(notch), @"frameRate": val(fps)} writeToFile:plistPath atomically:YES];
        apply(val(res), val(shape), val(window), val(notch), val(fps));
        NSString *now = options_resolution(data), *want = @(getenv("SIMS_GAME_RES") ?: "");
        if (now && want.length && wide_label(now) != wide_label(want) && !options_set_resolution(data, want))
            fprintf(stderr, "launcher: couldn't change the game's resolution in %s\n", options_path(data).UTF8String);
    };
    const char *shot = getenv("DS_LAUNCHER_SHOT");
    if (getenv("DS_NO_LAUNCHER") && !shot) { if (saved.count) apply(val(res), val(shape), val(window), val(notch), val(fps)); return 1; }

    NSString *updater = getenv("DS_UPDATER") ? @(getenv("DS_UPDATER")) : nil, *branch = getenv("DS_UPDATE_BRANCH") ? @(getenv("DS_UPDATE_BRANCH")) : @"main";
    NSString *built = getenv("DS_BUILT_COMMIT") ? @(getenv("DS_BUILT_COMMIT")) : @"";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:updater ?: @""]) updater = nil;
    DSRow *upd = [DSRow new]; upd.title = @"Updates";
    __block int ustate = updater ? UPD_CHECKING : UPD_NONE; __block NSString *latest = nil;
    upd.choices = update_choice(ustate, branch, built, nil);
    BOOL shotMode = shot != NULL;
    DSSection *display = [DSSection new], *saves = [DSSection new], *updSec = [DSSection new];
    display.title = @"Display"; display.rows = has_notch() ? @[res, window, notch, fps] : @[res, window, fps];
    saves.title = @"Saves"; saves.summary = ^NSString * { return @"Your neighbourhoods, in Finder"; };
    updSec.title = @"Updates"; updSec.summary = ^NSString * { NSDictionary *c = upd.choices[upd.index]; return [c[@"note"] length] ? [NSString stringWithFormat:@"%@ · %@", c[@"label"], c[@"note"]] : c[@"label"]; };
    DSLaunchView *v = [[DSLaunchView alloc] initWithFrame:NSMakeRect(0, 0, 780, 700)];
    v.top = @[shape]; v.sections = @[display, saves, updSec]; v.open = -1; v.hover = v.pressed = HIT_NONE;
    v.note = @"Sound, scrolling and detail: in the game's own Options. Cmd-Q asks the game to quit, as its own Quit does.";
    __weak DSLaunchView *wv = v; __weak DSRow *wu = upd;
    saves.activate = ^{
        NSString *dir = [[options_path(data) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            NSAlert *a = [NSAlert new]; a.messageText = @"No saves yet";
            a.informativeText = @"The game makes its neighbourhoods the first time it starts. Press Play, then come back here."; [a runModal]; return;
        }
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
    };
    updSec.activate = ^{ if (wu.activate) wu.activate(); };
    void (^check)(void) = ^{
        if (!updater) return;
        ustate = UPD_CHECKING; wu.choices = update_choice(ustate, branch, built, nil); wv.needsDisplay = YES;
        void (^done)(NSString *) = ^(NSString *l) {
            latest = l; ustate = !l ? UPD_ERROR : [l isEqualToString:built] ? UPD_CURRENT : UPD_AVAILABLE;
            wu.choices = update_choice(ustate, branch, built, l); wv.needsDisplay = YES;
        };
        if (shotMode) { done(update_check(updater)); return; }               /* development: the result in the image */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ NSString *l = update_check(updater); on_main(^{ done(l); }); });
    };
    check();
    upd.activate = ^{
        if (ustate == UPD_CHECKING) return;
        if (ustate != UPD_AVAILABLE) { check(); return; }
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Update to the newest %@?", [branch isEqualToString:@"nightly"] ? @"Nightly" : @"version"];
        a.informativeText = [NSString stringWithFormat:@"The %@ branch (%@) is downloaded from GitHub and the app is rebuilt from your own copy of the game, "
                             "which takes a few minutes. Your game folder, neighbourhoods and settings are kept. The app restarts when it is done.", branch, short_commit(latest)];
        [a addButtonWithTitle:@"Update"]; [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        NSString *logPath = [data stringByAppendingPathComponent:@"update.log"];
        if (update_run(wv.window, updater, branch, logPath)) {   /* restart: the new app, then this one ends */
            NSString *app = [[[updater stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            NSTask *o = [NSTask new]; o.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"]; o.arguments = @[@"-n", app];
            [o launchAndReturnError:nil]; [o waitUntilExit];
            exit(0);
        }
        check();
    };
    v.backdrop = art(data, @"backdrop"); v.shot = art(data, @"shot");
    NSImage *logo = art(data, @"logo"); v.logo = logo ? trimmed(logo, 0) : nil;
    if (shot) {   /* development: the window as an image */
        const char *open = getenv("DS_LAUNCHER_OPEN");
        if (open) for (NSInteger i = 0; i < (NSInteger)v.sections.count; i++) if ([v.sections[i].title caseInsensitiveCompare:@(open)] == NSOrderedSame) v.open = i;
        if (getenv("DS_LAUNCHER_PICK")) shape.index = index_of(shape.choices, @(getenv("DS_LAUNCHER_PICK")), shape.index);
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds]; [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(shot) atomically:YES];
        if (getenv("DS_LAUNCHER_APPLY")) {             /* development: what Play would do */
            finish(); printf("game: %s; Options.iff: %s\n", getenv("SIMS_GAME_RES") ?: "-", (options_resolution(data) ?: @"(none)").UTF8String);
        }
        return 0;
    }

    NSWindow *w = [[NSWindow alloc] initWithContentRect:v.frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO;   /* ARC owns it: AppKit's default would release it again when the close button closes it (a crash on exit) */
    w.titlebarAppearsTransparent = YES; w.titleVisibility = NSWindowTitleHidden; w.movableByWindowBackground = YES; w.title = @"The Sims";
    w.backgroundColor = NSColor.blackColor; w.contentView = v; [w center]; [w makeFirstResponder:v];
    __block int result = 0;
    v.onPlay = ^{ result = 1; [NSApp stopModal]; };
    v.onQuit = ^{ result = 0; [NSApp stopModal]; };
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:w queue:nil usingBlock:^(NSNotification *n) { (void)n; [NSApp stopModal]; }];
    [NSApp activateIgnoringOtherApps:YES];
    [w makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:w];
    [w orderOut:nil];
    if (!result) return 0;
    finish();
    return 1;
}
