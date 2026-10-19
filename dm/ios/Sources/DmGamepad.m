// Virtual gamepad (Nintendo button positions) + physical controllers (GameController). Both are merged and handed to the host through dm_input_set (hle_hid.c, bit layout in dm_input.h).
//   Two layouts; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D") switches them, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_FULL).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed for other profiles; Wonder 2D floats from the first left-half touch, follows excess travel, and hides on release);
//     Mario Wonder uses fixed enlarged rounded-rectangle shoulders, plus the inset X/A, Y/B rounded-square grid, with larger hit targets and a narrow Y+B bridge. Other profiles keep
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick (inward of and below the diamond, a smaller ring)
//     and L3 / R3 (small round keys in the top row, inward of ZL / ZR). Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the two sticks has the smallest distance / grab radius (the left stick's grab circle borders the D-pad).
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller).
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm_input.h"
#include "game_profile.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP };   // which control a touch holds

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_pad_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry, g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static int tilted(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y > (int64_t)4000 * 4000; }
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    int32_t lx = g_touch_lx, ly = g_touch_ly, rx = g_touch_rx, ry = g_touch_ry;
    if (tilted(g_pad_lx, g_pad_ly)) { lx = g_pad_lx; ly = g_pad_ly; }   // a tilted physical stick wins
    if (tilted(g_pad_rx, g_pad_ry)) { rx = g_pad_rx; ry = g_pad_ry; }
    dm_input_set(g_touch_btn | g_pad_btn, lx, ly, rx, ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_SHOULDER_W = 140, K_SHOULDER_H = 70.4, K_SHOULDER_CORNER = 18,
    K_SHOULDER_HIT_W = 156, K_SHOULDER_HIT_H = 88, K_SHOULDER_GAP = 96,
    K_SHOULDER_EDGE = 4, K_SHOULDER_FONT = 28,       // Wonder 2D: wide outer-edge buttons; upper/lower hit gap = 8
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_GRID_SIZE = 92, K_GRID_HIT = 110.4, K_GRID_CORNER = 25.3, K_GRID_FONT = 36.8,
    K_GRID_DX = 104, K_GRID_DY = 106, K_GRID_RIGHT = 49, K_GRID_BOTTOM = 30,
    K_GRID_HYSTERESIS = 4,                          // require a clear move before switching single keys in an overlap
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad / right stick centre from the outer edge and the bottom (inward of and below the left stick / the diamond, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60, K_RKNOB_R = 24,                // right stick: ring and knob radius
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 1 = 3D, 0 = 2D

@interface DmGamepad : UIView
@end
static __weak DmGamepad *g_view;

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // owning touches and their current positions (0 left, 1 right)
    CGPoint _floatingHome; CGSize _layoutSize;     // Wonder 2D: touch origin, following only beyond the ring radius
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring[2], *_knob[2];
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    BOOL _sticksShown;                             // a stick was held at the last refresh
    BOOL _full;                                    // the 3D layout is current
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static UIColor *k_shoulderIdle, *k_shoulderText;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
            k_shoulderIdle = [UIColor colorWithWhite:1 alpha:0.18]; k_shoulderText = [UIColor colorWithWhite:1 alpha:0.75];
        });
        for (int i = 0; i < 2; i++) {
            _ring[i] = shape(self.layer); _ring[i].fillColor = k_ringFill.CGColor;
            _knob[i] = shape(self.layer);
            CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
            [_knob[i] addSublayer:in];
        }
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(self.layer);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(self.layer); _swapLabel = label(_swap, @"");
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        _full = saved ? saved.boolValue : DM_GAME_PAD_FULL;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [self padsChanged];
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = fullOnly(b) && !_full;
    _ring[1].hidden = _knob[1].hidden = !_full;
    _swapLabel.string = _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)setFull:(BOOL)full {   // switch layouts: release every touch first (no key stays held), save, lay out again
    if (full == _full) return;
    [self reset];
    _full = full;
    [NSUserDefaults.standardUserDefaults setObject:@(full) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
// Restrict the requested layout to Wonder's 2D pad; retain the 3D right-stick space and all other profiles.
- (BOOL)faceGrid { return DM_GAME_PROGRAM_ID == 0x010015100B514000ull && !_full; }
- (BOOL)floatingStick { return self.faceGrid; }
- (CGPoint)faceCenter {
    CGFloat u = self.u;
    if (self.faceGrid) {
        UIEdgeInsets i = self.safeAreaInsets;
        // Bottom controls can enter the side padding; the island is above this group.
        CGFloat right = MAX(K_GRID_RIGHT * u, i.right * K_CORNER_IN + (K_GRID_HIT - K_GRID_SIZE) * u / 2);
        CGFloat bottom = MAX(K_GRID_BOTTOM * u, i.bottom + (K_GRID_HIT - K_GRID_SIZE) * u / 2);
        return CGPointMake(CGRectGetMaxX(self.bounds) - right - (K_GRID_SIZE + K_GRID_DX) * u / 2,
                           CGRectGetMaxY(self.bounds) - bottom - (K_GRID_SIZE + K_GRID_DY) * u / 2);
    }
    CGRect s = self.corner; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u);
}
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    if (self.faceGrid) {
        CGFloat dx = K_GRID_DX * self.u / 2, dy = K_GRID_DY * self.u / 2;
        return CGPointMake(c.x + ((b == B_A || b == B_B) ? dx : -dx),
                           c.y + ((b == B_Y || b == B_B) ? dy : -dy));
    }
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGRect)faceRect:(int)b size:(CGFloat)size {
    CGPoint c = [self facePos:b]; CGFloat w = size * self.u;
    return CGRectMake(c.x - w / 2, c.y - w / 2, w, w);
}
- (CGPoint)stickHome:(int)i { CGRect s = self.corner; CGFloat u = self.u;
    if (!i && self.floatingStick && _stick[0]) return _floatingHome;
    return i ? side(s, 1, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u) : side(s, 0, K_STICK_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (BOOL)floatingAt:(CGPoint)p {
    CGRect area = CGRectInset(self.safe, 8 * self.u, 8 * self.u);
    area.size.width = MAX(0, CGRectGetMidX(self.bounds) - CGRectGetMinX(area));
    return CGRectContainsPoint(area, p);
}
- (void)moveStick:(int)i to:(CGPoint)p {
    _stickNow[i] = p;
    if (!i && self.floatingStick) {
        CGFloat dx = p.x - _floatingHome.x, dy = p.y - _floatingHome.y, d = hypot(dx, dy), r = [self stickR:0];
        if (d > r) _floatingHome = CGPointMake(p.x - dx * r / d, p.y - dy * r / d);
    }
}
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u); }
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    if (self.faceGrid) return side(self.bounds, b == B_ZR || b == B_R, (K_SHOULDER_EDGE + K_SHOULDER_HIT_W / 2) * u,
                                   CGRectGetMinY(s) + (K_SHOULDER_EDGE + K_SHOULDER_HIT_H / 2 + (z ? 0 : K_SHOULDER_GAP)) * u);
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGRect)shoulderRect:(int)b hit:(BOOL)hit {
    CGPoint c = [self dropCenter:b]; CGFloat u = self.u;
    CGFloat w = (hit ? K_SHOULDER_HIT_W : K_SHOULDER_W) * u, h = (hit ? K_SHOULDER_HIT_H : K_SHOULDER_H) * u;
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
}
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? (self.faceGrid ? CGRectContainsPoint([self shoulderRect:b hit:YES], p) : dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35)
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p previous:(uint64_t)previous {
    if (self.faceGrid) {
        uint64_t candidates = 0; int nearest = -1; CGFloat best = CGFLOAT_MAX;
        for (int b = B_A; b <= B_Y; b++) {
            if (!CGRectContainsPoint([self faceRect:b size:K_GRID_HIT], p)) continue;
            candidates |= 1ull << b;
            CGFloat d = dist(p, [self facePos:b]);
            if (d < best) { best = d; nearest = b; }
        }
        if (!candidates) return 0;   // moving beyond the expanded targets releases the keys
        const uint64_t yb = (1ull << B_Y) | (1ull << B_B);
        // Only the narrow overlap between Y and B permits a one-finger chord.
        // Keep it below the row junction so touching the centre cannot activate three/four keys.
        if ((candidates & yb) == yb && p.y >= self.faceCenter.y + 5 * self.u) return yb;
        uint64_t held = previous & candidates;
        if (held && !(held & (held - 1))) {
            for (int b = B_A; b <= B_Y; b++) if (held == (1ull << b)) {
                if (dist(p, [self facePos:b]) <= best + K_GRID_HYSTERESIS * self.u) return held;
            }
        }
        return 1ull << nearest;
    }
    // Original diamond: points between two keys may hold both.
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the ring centre (clamped to the ring)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickHome:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL sticks = _stick[0] || _stick[1];
    if (changed || sticks || _sticksShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _sticksShown = sticks;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self]; int hit = [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        if (self.faceGrid) {
            uint64_t face = [self faceAt:p previous:0];
            if (face) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@(face) forKey:t]; continue; }
        }
        if (self.floatingStick) {
            if (!_stick[0] && [self floatingAt:p]) {
                [_owner setObject:@(C_STICK) forKey:t]; _stick[0] = t;
                _floatingHome = _stickNow[0] = p;   // no direction on touch-down, even at the edge
            }
            continue;   // a second finger cannot steal the left stick or create a fixed-origin one
        }
        // Original diamond, D-pad, sticks: smallest distance / grab radius, if <= 1.
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = self.faceGrid ? CGFLOAT_MAX : dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        for (int i = 0; i < (_full ? 2 : 1); i++) if (!_stick[i]) {
            CGFloat s = dist(p, [self stickHome:i]) / ([self stickR:i] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; idx = i; } }
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p previous:0]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
    }
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p previous:[_faceOf objectForKey:t].unsignedLongLongValue]) forKey:t];
        else if (c == C_STICK) [self moveStick:(int)(v >> 8) to:p];
    }
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO;
    for (UITouch *t in ts) {
        if (ended && ([_owner objectForKey:t].unsignedLongLongValue & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    [self recompute];
    if (swap) [self setFull:!_full];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(_layoutSize, self.bounds.size)) {
        _layoutSize = self.bounds.size;
        if (self.floatingStick) [self reset];   // rotation/resizing releases floating input
    }
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = B_A; b <= B_Y; b++) {
        CGPoint c = [self facePos:b];
        CGPathRef path = self.faceGrid ? CGPathCreateWithRoundedRect([self faceRect:b size:K_GRID_SIZE], K_GRID_CORNER * u, K_GRID_CORNER * u, NULL)
                                      : circlePath(c, self.faceR);
        setPath(_key[b], path); placeLabel(_label[b], c, (self.faceGrid ? K_GRID_FONT : 20) * u);
    }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            if (self.faceGrid) {
                setPath(_key[b], CGPathCreateWithRoundedRect([self shoulderRect:b hit:NO], K_SHOULDER_CORNER * u, K_SHOULDER_CORNER * u, NULL));
                placeLabel(_label[b], c, K_SHOULDER_FONT * u);
            } else {
                setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);
            }
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    for (int i = 0; i < 2; i++) {
        setPath(_ring[i], circlePath([self stickHome:i], [self stickR:i]));
        CGFloat k = (i ? K_RKNOB_R : K_KNOB_R) * u; _knob[i].bounds = CGRectMake(0, 0, 2 * k, 2 * k);
        setPath(_knob[i], circlePath(CGPointMake(k, k), k));
        CAShapeLayer *in = (CAShapeLayer *)_knob[i].sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
        in.frame = _knob[i].bounds; in.path = ip; CGPathRelease(ip);
    }
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; if (self.floatingStick) [self reset]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        BOOL shoulder = self.faceGrid && isDrop(b);
        _key[b].fillColor = (on ? k_on : shoulder ? k_shoulderIdle : k_idle).CGColor;
        _label[b].foregroundColor = (on ? k_textOn : shoulder ? k_shoulderText : k_text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    for (int i = 0; i < 2; i++) {
        if (!i) {
            BOOL floating = self.floatingStick;
            _ring[0].hidden = _knob[0].hidden = floating && !_stick[0];
            // Translate the existing ring path; dragging never rebuilds its geometry.
            CGPoint home = [self stickHome:0];
            CGPathRef path = _ring[0].path;
            CGRect box = path ? CGPathGetBoundingBox(path) : CGRectZero;
            _ring[0].position = floating && _stick[0] && path ? CGPointMake(home.x - CGRectGetMidX(box), home.y - CGRectGetMidY(box)) : CGPointZero;
        }
        CGPoint h = [self stickHome:i], o = [self knobOffset:i];
        _knob[i].position = CGPointMake(h.x + o.x, h.y + o.y); _knob[i].fillColor = (_stick[i] ? k_on : k_idle).CGColor;
    }
    [CATransaction commit];
}

// ---- Physical controllers ----
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.buttonB, B_A); K(g.buttonA, B_B); K(g.buttonY, B_X); K(g.buttonX, B_Y);   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    pthread_mutex_lock(&g_mu);
    g_pad_btn = m; g_pad_lx = axis(g.leftThumbstick.xAxis.value); g_pad_ly = axis(g.leftThumbstick.yAxis.value);
    g_pad_rx = axis(g.rightThumbstick.xAxis.value); g_pad_ry = axis(g.rightThumbstick.yAxis.value);
    pthread_mutex_unlock(&g_mu);
    publish();
}
- (void)padsChanged {
    BOOL any = NO;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) {
        any = YES; c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        read_pad(c.extendedGamepad);
    }
    if (!any) { pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish(); }
    dispatch_async(dispatch_get_main_queue(), ^{ self.hidden = any; if (any) [self reset]; });
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish();
}
