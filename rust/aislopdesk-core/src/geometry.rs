//! Pure 2-D geometry + aspect-fit math — the canonical geometry logic (the Swift shell's `Geometry.swift` mirrors it).
//!
//! These types mirror `CGPoint`/`CGSize`/`CGRect` without any platform dependency so
//! the renderer's forward transform and the input encoder's inverse transform derive
//! from one shared source and can never drift (incl. across a fit↔fill toggle).

/// A pure 2-D point (host-space, points).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoPoint {
    /// Horizontal coordinate.
    pub x: f64,
    /// Vertical coordinate.
    pub y: f64,
}

impl VideoPoint {
    /// Builds a point.
    #[must_use]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// A pure 2-D size (points).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoSize {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl VideoSize {
    /// Builds a size.
    #[must_use]
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

/// A pure rectangle (origin + size), in whatever coordinate space the caller states.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoRect {
    /// Lower/upper-left origin (coordinate-space dependent).
    pub origin: VideoPoint,
    /// Extent.
    pub size: VideoSize,
}

impl VideoRect {
    /// Builds a rect from an origin and size.
    #[must_use]
    pub const fn new(origin: VideoPoint, size: VideoSize) -> Self {
        Self { origin, size }
    }

    /// Builds a rect from scalar components.
    #[must_use]
    pub const fn xywh(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            origin: VideoPoint::new(x, y),
            size: VideoSize::new(width, height),
        }
    }

    /// Minimum x (origin.x).
    #[must_use]
    pub const fn min_x(&self) -> f64 {
        self.origin.x
    }

    /// Minimum y (origin.y).
    #[must_use]
    pub const fn min_y(&self) -> f64 {
        self.origin.y
    }

    /// Maximum x (origin.x + width).
    #[must_use]
    pub fn max_x(&self) -> f64 {
        self.origin.x + self.size.width
    }

    /// Maximum y (origin.y + height).
    #[must_use]
    pub fn max_y(&self) -> f64 {
        self.origin.y + self.size.height
    }

    /// The area of intersection with `other` (0 when disjoint). Used by the
    /// multi-monitor coordinate-mapping screen pick.
    #[must_use]
    pub fn intersection_area(&self, other: &Self) -> f64 {
        let ix = 0.0_f64.max(self.max_x().min(other.max_x()) - self.min_x().max(other.min_x()));
        let iy = 0.0_f64.max(self.max_y().min(other.max_y()) - self.min_y().max(other.min_y()));
        ix * iy
    }

    // ----- CoreGraphics CGRect-faithful geometry (host-side) -----
    //
    // The host capture-region / placement / virtual-display math uses CGRect's
    // `union`/`intersection`/`isNull`/standardized `width`/`height`/`maxX`. These mirror
    // CoreGraphics exactly; the Swift shell's `CaptureRegionMath`, `WindowPlacementMath`,
    // `SystemDialogDetector`, and `VirtualDisplayPlanner` track this core byte/behaviour-identically.
    // NOTE: the RAW `min_x`/`max_x`/`max_y` above intentionally do NOT standardize (their
    // only caller, the coordinate-mapping screen pick, deals exclusively in positive rects).
    // The methods below DO standardize, matching CG — keep the two families distinct.

    /// The CoreGraphics null rectangle (`CGRectNull`): an empty rect at an infinite origin,
    /// returned by [`intersection`](Self::intersection)'s caller for the "no overlap" outcome.
    pub const NULL: Self = Self::xywh(f64::INFINITY, f64::INFINITY, 0.0, 0.0);

    /// `true` for the CoreGraphics null rectangle (infinite origin) — mirrors `CGRectIsNull`.
    #[must_use]
    pub const fn is_null(&self) -> bool {
        self.origin.x.is_infinite() || self.origin.y.is_infinite()
    }

    /// The standardized rect (non-negative size, origin at the lower corner) — mirrors
    /// `CGRectStandardize`. A negative width/height flips the origin so the size is positive.
    #[must_use]
    pub fn standardized(&self) -> Self {
        Self::xywh(
            self.origin.x + self.size.width.min(0.0),
            self.origin.y + self.size.height.min(0.0),
            self.size.width.abs(),
            self.size.height.abs(),
        )
    }

    /// Standardized width — always non-negative (= `|size.width|`). Mirrors `CGRect.width`.
    #[must_use]
    pub const fn width(&self) -> f64 {
        self.size.width.abs()
    }

    /// Standardized height — always non-negative (= `|size.height|`). Mirrors `CGRect.height`.
    #[must_use]
    pub const fn height(&self) -> f64 {
        self.size.height.abs()
    }

    /// Standardized right edge — mirrors `CGRect.maxX` (differs from the raw [`max_x`](Self::max_x)
    /// only for a negative width). Used by the virtual-display `originToRight` placement.
    #[must_use]
    pub fn std_max_x(&self) -> f64 {
        self.origin.x.max(self.origin.x + self.size.width)
    }

    /// The intersection with `other`, or `None` ONLY when they are strictly disjoint (a real
    /// gap on some axis) — exactly `CGRectIntersection` returning `CGRectNull`. An EDGE-TOUCH
    /// or a zero-WIDTH/HEIGHT overlap that still lies within both rects returns a non-null,
    /// zero-AREA rect (HW-verified: `CGRectIntersection((0,0,10,10),(10,0,5,5))` ⇒
    /// `(10,0,0,5)`, `isNull == false`). The null test is therefore STRICT `<` per axis, NOT
    /// `<=` — a `<=` test wrongly nulls the touching case and diverges from CoreGraphics (this
    /// matters for `CaptureRegionMath`'s zero-area-target fallback, which returns the clamped
    /// degenerate rect, not `CGRectNull`). Both rects are standardized first; the result has a
    /// non-negative size.
    #[must_use]
    pub fn intersection(&self, other: &Self) -> Option<Self> {
        let a = self.standardized();
        let b = other.standardized();
        let x1 = a.min_x().max(b.min_x());
        let y1 = a.min_y().max(b.min_y());
        let x2 = a.max_x().min(b.max_x());
        let y2 = a.max_y().min(b.max_y());
        if x2 < x1 || y2 < y1 {
            None // strictly disjoint (a real gap) → CGRectNull
        } else {
            // x2 == x1 and/or y2 == y1 (edge-touch / degenerate) is a non-null zero-area rect.
            Some(Self::xywh(x1, y1, x2 - x1, y2 - y1))
        }
    }

    /// The bounding box of `self` and `other` — mirrors `CGRectUnion`. If either rect is the
    /// null rect, returns the other (standardized), matching CoreGraphics' null-is-identity rule.
    /// Both rects are standardized first; the result has a non-negative size.
    #[must_use]
    pub fn union(&self, other: &Self) -> Self {
        if self.is_null() {
            return other.standardized();
        }
        if other.is_null() {
            return self.standardized();
        }
        let a = self.standardized();
        let b = other.standardized();
        let x1 = a.min_x().min(b.min_x());
        let y1 = a.min_y().min(b.min_y());
        let x2 = a.max_x().max(b.max_x());
        let y2 = a.max_y().max(b.max_y());
        Self::xywh(x1, y1, x2 - x1, y2 - y1)
    }
}

/// How the decoded video is scaled into the on-screen layer.
///
/// Both modes PRESERVE the
/// native aspect ratio (neither stretches): `Fit` letterboxes/pillarboxes so the whole
/// remote window is visible; `Fill` covers the pane, cropping the overflowing axis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoContentMode {
    /// Contain: the whole video sits inside the view (letterbox/pillarbox bars).
    Fit,
    /// Cover: the video fills the view; the longer axis overflows and is cropped.
    Fill,
}

/// Aspect-fit geometry — the single source of truth for where the decoded video is
/// drawn inside the layer (the Swift shell's `AspectFit` mirrors it).
pub mod aspect_fit {
    use super::{VideoContentMode, VideoPoint, VideoRect, VideoSize};

    /// The centred rect the displayed video occupies inside a `view_size` layer,
    /// preserving the native aspect ratio.
    ///
    /// In `Fit` the rect is contained (centred,
    /// with bars); in `Fill` it covers the view (centred, may exceed it — that overflow
    /// is the crop). Falls back to the full `view_size` rect for any non-positive
    /// dimension (degenerate input placed sensibly).
    #[must_use]
    pub fn displayed_video_rect(
        view_size: VideoSize,
        video_native_size: VideoSize,
        mode: VideoContentMode,
    ) -> VideoRect {
        let (vw, vh) = (video_native_size.width, video_native_size.height);
        let (cap_w, cap_h) = (view_size.width, view_size.height);
        if !(vw > 0.0 && vh > 0.0 && cap_w > 0.0 && cap_h > 0.0) {
            return VideoRect::xywh(0.0, 0.0, cap_w.max(0.0), cap_h.max(0.0));
        }
        // `Fit` scales to the SMALLER axis ratio (contain); `Fill` to the LARGER (cover).
        // A single uniform scale, so neither distorts the aspect.
        let scale_x = cap_w / vw;
        let scale_y = cap_h / vh;
        let scale = if mode == VideoContentMode::Fit {
            scale_x.min(scale_y)
        } else {
            scale_x.max(scale_y)
        };
        let w = vw * scale;
        let h = vh * scale;
        let ox = (cap_w - w) / 2.0;
        let oy = (cap_h - h) / 2.0;
        VideoRect::xywh(ox, oy, w, h)
    }

    /// FORWARD render transform: maps a host-window-space point to where it is drawn in
    /// the layer's view space.
    ///
    /// The exact inverse of the input encoder's `normalize` and
    /// the renderer's aspect-fit + zoom/pan crop. Pan is clamped identically to the
    /// renderer (`pan_limit = 0.5·(1 - 1/zoom)`).
    #[must_use]
    pub fn view_point(
        host_point: VideoPoint,
        view_size: VideoSize,
        video_native_size: VideoSize,
        zoom: f64,
        pan: VideoPoint,
        mode: VideoContentMode,
    ) -> VideoPoint {
        let su = if video_native_size.width > 0.0 {
            host_point.x / video_native_size.width
        } else {
            0.0
        };
        let sv = if video_native_size.height > 0.0 {
            host_point.y / video_native_size.height
        } else {
            0.0
        };
        let z = zoom.max(1.0);
        let inv_zoom = 1.0 / z;
        let pan_limit = 0.5 * (1.0 - inv_zoom);
        let px = pan.x.max(-pan_limit).min(pan_limit);
        let py = pan.y.max(-pan_limit).min(pan_limit);
        let du = (su - 0.5 - px) * z + 0.5;
        let dv = (sv - 0.5 - py) * z + 0.5;
        let r = displayed_video_rect(view_size, video_native_size, mode);
        VideoPoint::new(
            r.origin.x + du * r.size.width,
            r.origin.y + dv * r.size.height,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::aspect_fit::{displayed_video_rect, view_point};
    use super::{VideoContentMode, VideoPoint, VideoRect, VideoSize};

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn intersection_area_disjoint_is_zero() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        let b = VideoRect::xywh(20.0, 20.0, 5.0, 5.0);
        approx(a.intersection_area(&b), 0.0);
    }

    #[test]
    fn intersection_area_overlap() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        let b = VideoRect::xywh(5.0, 5.0, 10.0, 10.0);
        approx(a.intersection_area(&b), 25.0);
    }

    #[test]
    fn fit_letterboxes_wide_view() {
        // 16:9 video into a square view → pillarbox? video wider than view → letterbox top/bottom.
        let r = displayed_video_rect(
            VideoSize::new(100.0, 100.0),
            VideoSize::new(200.0, 100.0),
            VideoContentMode::Fit,
        );
        // scale = min(100/200, 100/100)=0.5 → 100x50 centred.
        approx(r.size.width, 100.0);
        approx(r.size.height, 50.0);
        approx(r.origin.x, 0.0);
        approx(r.origin.y, 25.0);
    }

    #[test]
    fn fill_covers_and_overflows() {
        let r = displayed_video_rect(
            VideoSize::new(100.0, 100.0),
            VideoSize::new(200.0, 100.0),
            VideoContentMode::Fill,
        );
        // scale = max(0.5,1.0)=1.0 → 200x100, origin x=-50.
        approx(r.size.width, 200.0);
        approx(r.size.height, 100.0);
        approx(r.origin.x, -50.0);
        approx(r.origin.y, 0.0);
    }

    #[test]
    fn degenerate_falls_back_to_view() {
        let r = displayed_video_rect(
            VideoSize::new(80.0, 60.0),
            VideoSize::new(0.0, 0.0),
            VideoContentMode::Fit,
        );
        assert_eq!(r, VideoRect::xywh(0.0, 0.0, 80.0, 60.0));
    }

    #[test]
    fn view_point_center_maps_to_rect_center() {
        let p = view_point(
            VideoPoint::new(100.0, 50.0), // center of a 200x100 video
            VideoSize::new(100.0, 100.0),
            VideoSize::new(200.0, 100.0),
            1.0,
            VideoPoint::new(0.0, 0.0),
            VideoContentMode::Fit,
        );
        // displayed rect is 100x50 at (0,25); center maps to (50, 50).
        approx(p.x, 50.0);
        approx(p.y, 50.0);
    }

    // ----- CGRect-faithful geometry -----

    #[test]
    fn width_height_are_standardized_abs() {
        let r = VideoRect::xywh(10.0, 20.0, -30.0, -40.0);
        approx(r.width(), 30.0);
        approx(r.height(), 40.0);
        // raw size is untouched.
        approx(r.size.width, -30.0);
    }

    #[test]
    fn standardized_flips_negative_size() {
        let s = VideoRect::xywh(10.0, 20.0, -30.0, -40.0).standardized();
        assert_eq!(s, VideoRect::xywh(-20.0, -20.0, 30.0, 40.0));
    }

    #[test]
    fn std_max_x_handles_negative_width() {
        approx(VideoRect::xywh(100.0, 0.0, 50.0, 10.0).std_max_x(), 150.0);
        approx(VideoRect::xywh(100.0, 0.0, -50.0, 10.0).std_max_x(), 100.0);
    }

    #[test]
    fn intersection_overlap_partial() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        let b = VideoRect::xywh(5.0, 5.0, 10.0, 10.0);
        assert_eq!(
            a.intersection(&b),
            Some(VideoRect::xywh(5.0, 5.0, 5.0, 5.0))
        );
    }

    #[test]
    fn intersection_disjoint_is_null_but_edge_touch_is_zero_area() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        // Strictly disjoint (a real x-gap) → CGRectNull.
        assert_eq!(a.intersection(&VideoRect::xywh(20.0, 0.0, 5.0, 5.0)), None);
        // Edge-touch (x2 == x1 == 10): CGRectIntersection returns a non-null ZERO-WIDTH rect
        // (HW-verified `(10,0,0,5)`, isNull == false), NOT CGRectNull.
        assert_eq!(
            a.intersection(&VideoRect::xywh(10.0, 0.0, 5.0, 5.0)),
            Some(VideoRect::xywh(10.0, 0.0, 0.0, 5.0))
        );
    }

    #[test]
    fn intersection_containment_returns_inner() {
        let outer = VideoRect::xywh(0.0, 0.0, 100.0, 100.0);
        let inner = VideoRect::xywh(10.0, 10.0, 20.0, 20.0);
        assert_eq!(outer.intersection(&inner), Some(inner));
    }

    #[test]
    fn union_bounding_box() {
        let a = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        let b = VideoRect::xywh(20.0, 20.0, 10.0, 10.0);
        assert_eq!(a.union(&b), VideoRect::xywh(0.0, 0.0, 30.0, 30.0));
    }

    #[test]
    fn union_with_null_is_identity() {
        let a = VideoRect::xywh(5.0, 6.0, 7.0, 8.0);
        assert_eq!(VideoRect::NULL.union(&a), a);
        assert_eq!(a.union(&VideoRect::NULL), a);
        assert!(VideoRect::NULL.is_null());
        assert!(!a.is_null());
    }
}
