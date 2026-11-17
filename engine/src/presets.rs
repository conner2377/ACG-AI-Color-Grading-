//! Built-in template library. Each template is a style layered on top of the physical
//! base correction (see `analysis::auto_correct`). Values are derived from common
//! professional grading practice (film emulation, cinematic split toning, portrait and
//! landscape workflows); see docs for sources.
//!
//! Every template only sets edit parameters (and, for a few, a small generated 3D LUT),
//! so applying one never resamples or regenerates pixels.

use crate::analysis::Scene;
use crate::recipe::{HslBand, Recipe, ToneWheel};

/// Template categories in display order.
pub const CATEGORIES: [&str; 10] =
    ["기본", "필름", "감성", "깊이감", "시네마", "인물", "풍경", "야경", "흑백", "특수"];

fn wheel(hue: f32, sat: f32) -> ToneWheel {
    ToneWheel { hue, sat }
}

/// Indices into the HSL band array.
pub mod band {
    pub const RED: usize = 0;
    pub const ORANGE: usize = 1;
    pub const YELLOW: usize = 2;
    pub const GREEN: usize = 3;
    pub const AQUA: usize = 4;
    pub const BLUE: usize = 5;
    pub const PURPLE: usize = 6;
    pub const MAGENTA: usize = 7;
}
use band::*;

fn t(name: &str, category: &str, description: &str) -> Recipe {
    Recipe {
        category: category.to_string(),
        description: description.to_string(),
        ..Recipe::named(name)
    }
}

/// Set HSL bands: (band, hue shift, sat, lum).
fn hsl(mut r: Recipe, bands: &[(usize, f32, f32, f32)]) -> Recipe {
    for &(b, h, s, l) in bands {
        r.hsl[b] = HslBand { hue: h, sat: s, lum: l };
    }
    r
}

fn mono_mix(r: f32, g: f32, b: f32) -> Option<[[f32; 3]; 3]> {
    Some([[r, g, b], [r, g, b], [r, g, b]])
}

/// Film-style tone curve: lifted toe, gentle S, rolled-off shoulder.
fn film_curve(black: f32, white: f32, s: f32) -> Vec<(f32, f32)> {
    vec![
        (0.0, black),
        (0.25, 0.25 - s + black * 0.4),
        (0.5, 0.5),
        (0.75, 0.75 + s - (1.0 - white) * 0.4),
        (1.0, white),
    ]
}

pub fn all() -> Vec<Recipe> {
    vec![
        // 기본
        natural(), vivid(), bright_airy(), clean_white(), soft_matte(),
        // 필름
        film(), portra(), fuji_pastel(), gold_film(), ektar_vivid(), classic_chrome(),
        classic_neg(), disposable(), faded_70s(), slide_film(), tungsten_800(), halation_film(),
        // 감성
        warm(), cool_moody(), dawn_blue(), golden_hour(), rainy_day(), autumn_brown(),
        summer_fresh(), winter_white(), dreamy(), retro_80s(), city_pop(), matte_pastel(),
        // 깊이감
        deep_rich(), dark_moody(), low_key(), painterly(), dense_film(),
        // 시네마
        cinematic(), teal_orange(), blockbuster(), bleach_bypass(), green_noir(),
        storybook_pastel(), desert_warm(), melancholy_cyan(),
        // 인물
        soft_portrait(), warm_skin(), portrait_film(), portrait_chic(), beauty_highkey(),
        // 풍경
        landscape(), deep_sky(), forest_mood(), ocean_fresh(), misty_morning(),
        // 야경
        night_city(), night_cinema(), neon_noir(),
        // 흑백
        bw_classic(), bw_contrast(), bw_soft(), bw_grain(), bw_selenium(), sepia(),
        // 특수
        infrared(), infrared_bw(), flash(), cross_process(), duotone_blue(),
    ]
}

pub fn by_name(name: &str) -> Option<Recipe> {
    all().into_iter().find(|r| r.name == name)
}

/// Template names suggested by auto-analysis for each scene, from subtle to strong.
pub fn suggestions(scene: Scene) -> Vec<&'static str> {
    let common = ["자연스럽게", "필름", "딥 앤 리치", "틸 앤 오렌지", "다크 무디", "흑백 클래식"];
    let specific: &[&str] = match scene {
        Scene::Portrait => &[
            "인물 화사하게", "따뜻한 피부", "인물 필름 소프트", "포트라 느낌", "밝고 화사하게",
            "인물 시크", "뷰티 하이키", "후지 파스텔", "몽환", "골든아워", "클래식 크롬", "파스텔 매트",
        ],
        Scene::Landscape => &[
            "풍경 강조", "깊은 하늘", "숲 무드", "바다 청량", "선명하게", "엑타 비비드",
            "슬라이드 필름", "안개 낀 아침", "골든아워", "블록버스터", "적외선", "클래식 크롬",
        ],
        Scene::Night => &[
            "야경 네온", "야경 시네마", "네온 누아르", "텅스텐 800", "로우키 드라마", "시티팝",
            "차가운 무드", "블리치 바이패스", "흑백 하이콘트라스트", "할레이션 필름",
        ],
        Scene::Sunset => &[
            "골든아워", "따뜻한 감성", "골드 필름", "사막 웜", "포트라 느낌", "블록버스터",
            "레트로 80s", "가을 브라운", "선명하게", "슬라이드 필름", "몽환",
        ],
        Scene::General => &[
            "선명하게", "포트라 느낌", "클래식 크롬", "클래식 네거티브", "따뜻한 감성", "차가운 무드",
            "블리치 바이패스", "밝고 화사하게", "레트로 80s", "일회용 카메라", "파스텔 매트", "흑백 필름 그레인",
        ],
    };
    let mut v: Vec<&str> = Vec::new();
    for n in common.iter().take(1).chain(specific.iter()).chain(common.iter().skip(1)) {
        if !v.contains(n) {
            v.push(n);
        }
    }
    v
}

// ============================================================ 기본

pub fn natural() -> Recipe {
    Recipe { vibrance: 0.12, clarity: 0.05, texture: 0.05, ..t("자연스럽게", "기본", "원본에 충실한 깔끔한 보정") }
}

pub fn vivid() -> Recipe {
    Recipe {
        contrast: 0.25, vibrance: 0.4, saturation: 0.08, clarity: 0.18, texture: 0.15, sharpen: 0.2, dehaze: 0.08,
        ..t("선명하게", "기본", "대비와 채도를 높여 또렷하게")
    }
}

pub fn bright_airy() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.35, contrast: -0.2, highlights: -0.2, shadows: 0.35, whites: 0.15, blacks: 0.1,
            temperature: 0.05, saturation: -0.1, vibrance: 0.1, clarity: -0.1, fade: 0.15,
            grade_highlights: wheel(45.0, 0.15),
            ..t("밝고 화사하게", "기본", "밝고 가벼운 에어리 무드, 초록은 민트로 정리")
        },
        &[(GREEN, 25.0, -0.4, 0.15), (YELLOW, -10.0, -0.25, 0.1), (ORANGE, 0.0, -0.05, 0.12), (BLUE, -5.0, -0.2, 0.1)],
    )
}

pub fn clean_white() -> Recipe {
    Recipe {
        exposure: 0.2, contrast: 0.05, highlights: -0.1, whites: 0.25, temperature: -0.06, saturation: -0.1,
        vibrance: 0.05, clarity: 0.05,
        ..t("클린 화이트", "기본", "하얗고 깨끗한 톤, 제품·인테리어에 어울림")
    }
}

pub fn soft_matte() -> Recipe {
    Recipe {
        contrast: -0.15, highlights: -0.15, shadows: 0.15, saturation: -0.08, fade: 0.3,
        curve: film_curve(0.05, 0.96, 0.02),
        ..t("소프트 매트", "기본", "검정을 살짝 들어올린 부드러운 매트 톤")
    }
}

// ============================================================ 필름

pub fn film() -> Recipe {
    Recipe {
        contrast: -0.05, highlights: -0.2, saturation: -0.12, temperature: 0.08, fade: 0.35,
        grain: 0.25, grain_size: 0.35, halation: 0.15,
        grade_shadows: wheel(200.0, 0.3), grade_highlights: wheel(40.0, 0.3),
        curve: film_curve(0.04, 0.96, 0.02),
        ..t("필름", "필름", "들뜬 블랙, 따뜻한 하이라이트, 은은한 그레인")
    }
}

pub fn portra() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.1, contrast: -0.1, highlights: -0.3, shadows: 0.15, temperature: 0.1, tint: 0.03,
            saturation: -0.1, vibrance: 0.05, fade: 0.2, grain: 0.2, grain_size: 0.3, halation: 0.1,
            grade_shadows: wheel(190.0, 0.2), grade_midtones: wheel(35.0, 0.12), grade_highlights: wheel(45.0, 0.25),
            curve: film_curve(0.03, 0.97, 0.025),
            cal_red_hue: 0.1, cal_blue_hue: -0.15, cal_blue_sat: 0.1,
            ..t("포트라 느낌", "필름", "부드러운 대비, 고운 피부톤, 따뜻한 중간톤의 컬러 네거티브")
        },
        &[(ORANGE, 2.0, -0.08, 0.08), (GREEN, 15.0, -0.3, -0.05), (BLUE, -8.0, -0.15, 0.0), (YELLOW, -6.0, -0.1, 0.0)],
    )
}

pub fn fuji_pastel() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.25, contrast: -0.2, highlights: -0.25, shadows: 0.25, temperature: -0.05, tint: -0.03,
            saturation: -0.15, fade: 0.3, grain: 0.18,
            grade_shadows: wheel(165.0, 0.3), grade_highlights: wheel(320.0, 0.12),
            curve: film_curve(0.05, 0.97, 0.01),
            cal_green_hue: 0.15,
            ..t("후지 파스텔", "필름", "민트빛 그림자와 파스텔 톤, 밝은 노출")
        },
        &[(GREEN, 25.0, -0.2, 0.1), (AQUA, -10.0, 0.1, 0.05), (BLUE, -10.0, -0.1, 0.1), (ORANGE, 0.0, -0.1, 0.1)],
    )
}

pub fn gold_film() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.1, highlights: -0.2, temperature: 0.22, tint: 0.02, saturation: 0.05, vibrance: 0.1,
            fade: 0.2, grain: 0.3, grain_size: 0.45, halation: 0.2,
            grade_shadows: wheel(25.0, 0.2), grade_highlights: wheel(48.0, 0.4),
            curve: film_curve(0.03, 0.97, 0.03),
            ..t("골드 필름", "필름", "노란빛이 도는 따뜻하고 진한 소비자용 필름")
        },
        &[(YELLOW, -8.0, 0.2, 0.05), (GREEN, -10.0, -0.1, 0.0), (BLUE, -5.0, -0.2, -0.05), (RED, 0.0, 0.1, 0.0)],
    )
}

pub fn ektar_vivid() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.25, highlights: -0.15, saturation: 0.15, vibrance: 0.2, temperature: 0.04,
            grain: 0.1, clarity: 0.08,
            curve: film_curve(0.0, 1.0, 0.04),
            ..t("엑타 비비드", "필름", "고채도 풍경 필름, 진한 빨강·파랑")
        },
        &[(RED, 0.0, 0.2, -0.05), (BLUE, -5.0, 0.25, -0.15), (AQUA, -5.0, 0.1, -0.05), (ORANGE, 0.0, 0.0, 0.0)],
    )
}

pub fn classic_chrome() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.2, highlights: -0.2, shadows: -0.1, saturation: -0.25, temperature: -0.03,
            grade_shadows: wheel(195.0, 0.25), grade_highlights: wheel(40.0, 0.12),
            curve: vec![(0.0, 0.02), (0.25, 0.21), (0.5, 0.49), (0.75, 0.78), (1.0, 0.98)],
            ..t("클래식 크롬", "필름", "차분한 저채도와 단단한 그림자의 다큐 톤")
        },
        &[(RED, 0.0, -0.1, -0.05), (BLUE, -5.0, -0.1, -0.15), (GREEN, 5.0, -0.25, -0.05), (YELLOW, -5.0, -0.2, 0.0)],
    )
}

pub fn classic_neg() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.3, highlights: -0.2, shadows: -0.15, saturation: -0.15, tint: -0.05, fade: 0.1,
            grain: 0.15,
            grade_shadows: wheel(170.0, 0.35), grade_highlights: wheel(25.0, 0.2),
            curve_r: vec![(0.0, 0.0), (0.5, 0.48), (1.0, 1.0)],
            curve_b: vec![(0.0, 0.04), (0.5, 0.5), (1.0, 0.95)],
            ..t("클래식 네거티브", "필름", "단단한 대비, 시안빛 그림자, 붉은 기 도는 하이라이트")
        },
        &[(GREEN, 10.0, -0.15, -0.1), (RED, 5.0, 0.05, 0.0), (BLUE, 5.0, -0.1, -0.1)],
    )
}

pub fn disposable() -> Recipe {
    Recipe {
        exposure: 0.1, contrast: 0.25, highlights: 0.1, shadows: -0.15, tint: -0.06, temperature: 0.05,
        saturation: 0.08, fade: 0.25, grain: 0.45, grain_size: 0.6, vignette: -0.4, halation: 0.1,
        grade_shadows: wheel(150.0, 0.3), grade_highlights: wheel(50.0, 0.2), sharpen: 0.0, texture: -0.1,
        ..t("일회용 카메라", "필름", "플래시 감성, 초록빛 그림자, 굵은 그레인과 비네팅")
    }
}

pub fn faded_70s() -> Recipe {
    hsl(
        Recipe {
            contrast: -0.15, highlights: -0.2, temperature: 0.2, tint: 0.05, saturation: -0.25, fade: 0.55,
            grain: 0.3, grain_size: 0.5,
            grade_shadows: wheel(30.0, 0.25), grade_highlights: wheel(50.0, 0.3),
            curve_b: vec![(0.0, 0.08), (0.5, 0.47), (1.0, 0.9)],
            ..t("빛바랜 70년대", "필름", "누렇게 바랜 오래된 사진")
        },
        &[(BLUE, 15.0, -0.4, 0.1), (GREEN, -15.0, -0.3, 0.0)],
    )
}

pub fn slide_film() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.35, highlights: -0.1, blacks: -0.15, saturation: 0.2, vibrance: 0.15, tint: 0.03,
            clarity: 0.1, grain: 0.08,
            curve: vec![(0.0, 0.0), (0.25, 0.2), (0.5, 0.5), (0.75, 0.8), (1.0, 1.0)],
            ..t("슬라이드 필름", "필름", "깊은 블랙과 진한 색의 리버설 필름")
        },
        &[(GREEN, -5.0, 0.15, -0.1), (BLUE, 0.0, 0.2, -0.15), (MAGENTA, 0.0, 0.15, 0.0), (RED, 0.0, 0.1, -0.05)],
    )
}

pub fn tungsten_800() -> Recipe {
    hsl(
        Recipe {
            temperature: -0.3, tint: 0.05, contrast: 0.15, highlights: -0.15, saturation: 0.05, fade: 0.1,
            grain: 0.35, grain_size: 0.5, halation: 0.55, bloom: 0.1,
            grade_shadows: wheel(205.0, 0.35), grade_highlights: wheel(25.0, 0.25),
            ..t("텅스텐 800", "필름", "밤 조명용 필름: 시안 그림자와 붉은 할레이션")
        },
        &[(RED, 0.0, 0.15, 0.0), (AQUA, -10.0, 0.2, 0.0), (YELLOW, -15.0, 0.0, 0.0)],
    )
}

pub fn halation_film() -> Recipe {
    Recipe {
        contrast: 0.1, highlights: -0.2, saturation: -0.05, fade: 0.15, grain: 0.3, grain_size: 0.45,
        halation: 0.75, bloom: 0.12, temperature: 0.03,
        grade_shadows: wheel(195.0, 0.25), grade_highlights: wheel(30.0, 0.2),
        curve: film_curve(0.03, 0.96, 0.03),
        ..t("할레이션 필름", "필름", "밝은 빛 주변으로 붉은 번짐이 생기는 영화 필름")
    }
}

// ============================================================ 감성

pub fn warm() -> Recipe {
    Recipe {
        temperature: 0.25, tint: 0.05, vibrance: 0.15, shadows: 0.1, fade: 0.1,
        grade_highlights: wheel(45.0, 0.35), grade_shadows: wheel(25.0, 0.15),
        ..t("따뜻한 감성", "감성", "포근하고 따뜻한 햇살 느낌")
    }
}

pub fn cool_moody() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.2, contrast: 0.15, temperature: -0.25, saturation: -0.25, highlights: -0.25,
            grade_shadows: wheel(215.0, 0.4), grade_highlights: wheel(200.0, 0.1), vignette: -0.3, fade: 0.1,
            ..t("차가운 무드", "감성", "푸르고 차분한 저채도 무드")
        },
        &[(GREEN, 15.0, -0.45, -0.2), (ORANGE, 0.0, -0.15, 0.0)],
    )
}

pub fn dawn_blue() -> Recipe {
    Recipe {
        exposure: 0.05, contrast: -0.1, temperature: -0.35, tint: 0.08, saturation: -0.1, fade: 0.25,
        grade_shadows: wheel(225.0, 0.35), grade_highlights: wheel(300.0, 0.15), bloom: 0.1,
        ..t("새벽 블루", "감성", "새벽빛 같은 푸른 보랏빛 공기감")
    }
}

pub fn golden_hour() -> Recipe {
    hsl(
        Recipe {
            temperature: 0.3, tint: 0.06, contrast: 0.1, highlights: -0.25, shadows: 0.1, vibrance: 0.2,
            grade_highlights: wheel(40.0, 0.45), grade_midtones: wheel(30.0, 0.15), grade_shadows: wheel(15.0, 0.15),
            bloom: 0.15, halation: 0.1,
            ..t("골든아워", "감성", "해질녘 금빛 역광 느낌")
        },
        &[(ORANGE, -3.0, 0.1, 0.05), (YELLOW, -10.0, 0.1, 0.0), (BLUE, 10.0, -0.25, 0.0)],
    )
}

pub fn rainy_day() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.15, contrast: -0.05, temperature: -0.15, tint: -0.03, saturation: -0.35, fade: 0.25,
            highlights: -0.2, dehaze: -0.08, grade_shadows: wheel(195.0, 0.3), vignette: -0.2,
            ..t("비 오는 날", "감성", "물기 어린 차분한 회청색")
        },
        &[(GREEN, 15.0, -0.3, -0.1), (ORANGE, 0.0, -0.1, 0.0)],
    )
}

pub fn autumn_brown() -> Recipe {
    hsl(
        Recipe {
            temperature: 0.18, contrast: 0.1, saturation: -0.1, fade: 0.15, grain: 0.15,
            grade_shadows: wheel(25.0, 0.3), grade_highlights: wheel(40.0, 0.2),
            ..t("가을 브라운", "감성", "초록을 갈색·올리브로 바꾼 가을 톤")
        },
        &[(GREEN, -35.0, -0.45, -0.15), (YELLOW, -15.0, 0.0, -0.05), (ORANGE, -5.0, 0.15, -0.05), (BLUE, 0.0, -0.4, 0.0), (AQUA, 0.0, -0.4, 0.0)],
    )
}

pub fn summer_fresh() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.2, contrast: 0.1, temperature: -0.08, vibrance: 0.3, highlights: -0.15, shadows: 0.15,
            clarity: 0.05,
            ..t("여름 청량", "감성", "밝고 시원한 청록과 맑은 하늘")
        },
        &[(AQUA, -10.0, 0.3, 0.05), (BLUE, -5.0, 0.2, 0.0), (GREEN, 10.0, 0.05, 0.1), (YELLOW, -5.0, -0.1, 0.0)],
    )
}

pub fn winter_white() -> Recipe {
    Recipe {
        exposure: 0.25, contrast: -0.05, whites: 0.2, temperature: -0.18, saturation: -0.3, fade: 0.1,
        grade_shadows: wheel(215.0, 0.25),
        ..t("겨울 화이트", "감성", "눈 내린 듯 하얗고 차가운 톤")
    }
}

pub fn dreamy() -> Recipe {
    Recipe {
        exposure: 0.2, contrast: -0.25, highlights: -0.1, shadows: 0.2, saturation: -0.1, clarity: -0.3,
        texture: -0.2, fade: 0.3, bloom: 0.5, temperature: 0.05,
        grade_highlights: wheel(330.0, 0.15), grade_shadows: wheel(260.0, 0.15),
        ..t("몽환", "감성", "빛이 번지는 부드럽고 몽환적인 느낌")
    }
}

pub fn retro_80s() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.1, temperature: 0.1, tint: 0.1, saturation: 0.05, fade: 0.3, grain: 0.3, grain_size: 0.5,
            grade_shadows: wheel(260.0, 0.3), grade_highlights: wheel(35.0, 0.3), halation: 0.15,
            ..t("레트로 80s", "감성", "보랏빛 그림자와 바랜 따뜻한 하이라이트")
        },
        &[(MAGENTA, 0.0, 0.2, 0.0), (AQUA, 10.0, 0.1, 0.0), (GREEN, 10.0, -0.25, 0.0)],
    )
}

pub fn city_pop() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.1, contrast: 0.05, tint: 0.12, saturation: 0.05, vibrance: 0.15, fade: 0.25, bloom: 0.15,
            grade_shadows: wheel(195.0, 0.35), grade_highlights: wheel(330.0, 0.3),
            ..t("시티팝", "감성", "핑크와 시안이 섞인 80년대 도시 감성")
        },
        &[(AQUA, 0.0, 0.25, 0.05), (MAGENTA, 0.0, 0.25, 0.05), (BLUE, -10.0, 0.0, 0.05)],
    )
}

pub fn matte_pastel() -> Recipe {
    Recipe {
        exposure: 0.15, contrast: -0.25, saturation: -0.2, fade: 0.5,
        grade_highlights: wheel(330.0, 0.15), grade_shadows: wheel(180.0, 0.15),
        ..t("파스텔 매트", "감성", "물 빠진 파스텔과 매트한 블랙")
    }
}

// ============================================================ 깊이감

pub fn deep_rich() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.15, contrast: 0.25, highlights: -0.3, shadows: -0.05, blacks: -0.1, saturation: 0.05,
            vibrance: 0.1, clarity: 0.12, dehaze: 0.08, vignette: -0.25,
            grade_shadows: wheel(205.0, 0.3), grade_highlights: wheel(38.0, 0.25),
            curve: vec![(0.0, 0.0), (0.2, 0.15), (0.5, 0.48), (0.8, 0.83), (1.0, 0.98)],
            ..t("딥 앤 리치", "깊이감", "밀도 높은 색과 깊은 그림자, 영화 같은 무게감")
        },
        &[(ORANGE, 0.0, 0.05, -0.08), (RED, 0.0, 0.1, -0.12), (GREEN, 10.0, -0.1, -0.2), (BLUE, -8.0, 0.05, -0.2), (YELLOW, -5.0, 0.0, -0.1)],
    )
}

pub fn dark_moody() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.4, contrast: 0.2, highlights: -0.35, shadows: -0.05, saturation: -0.3, fade: 0.12,
            temperature: 0.03, clarity: 0.1, vignette: -0.4,
            grade_shadows: wheel(200.0, 0.3), grade_highlights: wheel(35.0, 0.2),
            ..t("다크 무디", "깊이감", "어둡고 가라앉은 감성, 초록과 파랑을 눌러줌")
        },
        &[(GREEN, 20.0, -0.5, -0.3), (BLUE, -10.0, -0.3, -0.25), (YELLOW, -10.0, -0.25, -0.1), (ORANGE, 0.0, 0.0, -0.05)],
    )
}

pub fn low_key() -> Recipe {
    Recipe {
        exposure: -0.5, contrast: 0.35, highlights: -0.1, shadows: -0.3, blacks: -0.2, saturation: -0.1,
        clarity: 0.15, vignette: -0.5,
        grade_shadows: wheel(220.0, 0.2),
        ..t("로우키 드라마", "깊이감", "빛이 닿은 곳만 살린 극적인 어둠")
    }
}

pub fn painterly() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.1, contrast: 0.15, highlights: -0.35, shadows: 0.15, saturation: 0.05, vibrance: 0.15,
            clarity: -0.1, texture: -0.15, dehaze: 0.05, temperature: 0.08, vignette: -0.3,
            grade_shadows: wheel(30.0, 0.15), grade_highlights: wheel(45.0, 0.2),
            ..t("유화 같은", "깊이감", "부드러운 질감과 깊고 따뜻한 색, 고전 회화 느낌")
        },
        &[(GREEN, -10.0, -0.2, -0.15), (BLUE, 0.0, -0.1, -0.2), (RED, 0.0, 0.1, -0.1), (ORANGE, 0.0, 0.05, -0.05)],
    )
}

pub fn dense_film() -> Recipe {
    Recipe {
        exposure: -0.2, contrast: 0.15, highlights: -0.3, saturation: 0.08, fade: 0.08, grain: 0.25,
        halation: 0.2, vignette: -0.2,
        grade_shadows: wheel(185.0, 0.3), grade_midtones: wheel(30.0, 0.1), grade_highlights: wheel(42.0, 0.3),
        curve: film_curve(0.02, 0.95, 0.04),
        ..t("밀도 높은 필름", "깊이감", "살짝 언더 노출된 진하고 쫀득한 필름 톤")
    }
}

// ============================================================ 시네마

pub fn cinematic() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.2, highlights: -0.25, shadows: -0.1, saturation: -0.1, vignette: -0.25,
            grade_shadows: wheel(212.0, 0.45), grade_highlights: wheel(38.0, 0.35),
            ..t("시네마틱", "시네마", "푸른 그림자와 따뜻한 하이라이트의 영화 톤")
        },
        &[(ORANGE, -3.0, 0.1, 0.05), (BLUE, -12.0, -0.05, -0.1), (GREEN, 20.0, -0.35, -0.1)],
    )
}

pub fn teal_orange() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.25, highlights: -0.25, shadows: -0.05, saturation: -0.05, vibrance: 0.1, vignette: -0.2,
            grade_shadows: wheel(188.0, 0.6), grade_highlights: wheel(32.0, 0.45),
            ..t("틸 앤 오렌지", "시네마", "청록 배경과 주황 피부의 블록버스터 보색")
        },
        &[(ORANGE, -2.0, 0.15, 0.05), (YELLOW, -15.0, -0.1, 0.0), (GREEN, 40.0, -0.4, -0.1), (AQUA, 0.0, 0.2, -0.05), (BLUE, -20.0, 0.1, -0.1)],
    )
}

pub fn blockbuster() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.35, highlights: -0.3, shadows: -0.1, blacks: -0.1, saturation: 0.05, clarity: 0.2,
            dehaze: 0.1, vignette: -0.3, temperature: 0.05,
            grade_shadows: wheel(200.0, 0.5), grade_highlights: wheel(35.0, 0.4),
            ..t("블록버스터", "시네마", "강한 대비와 선명함의 액션 영화 톤")
        },
        &[(ORANGE, 0.0, 0.1, 0.05), (BLUE, -10.0, 0.1, -0.15), (GREEN, 25.0, -0.3, -0.1)],
    )
}

pub fn bleach_bypass() -> Recipe {
    Recipe {
        contrast: 0.45, highlights: -0.15, saturation: -0.5, clarity: 0.25, texture: 0.15, blacks: -0.1,
        grain: 0.15, vignette: -0.25, skin_protect: 0.2,
        curve: vec![(0.0, 0.0), (0.25, 0.19), (0.5, 0.5), (0.75, 0.82), (1.0, 1.0)],
        ..t("블리치 바이패스", "시네마", "은빛이 남은 듯한 저채도·고대비 전쟁영화 톤")
    }
}

pub fn green_noir() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.25, highlights: -0.2, tint: -0.2, saturation: -0.3, vignette: -0.3,
            grade_shadows: wheel(140.0, 0.45), grade_midtones: wheel(110.0, 0.15), grade_highlights: wheel(70.0, 0.15),
            ..t("그린 누아르", "시네마", "초록빛이 감도는 디지털 스릴러 톤")
        },
        &[(ORANGE, 15.0, -0.2, 0.0), (BLUE, -30.0, -0.3, -0.1)],
    )
}

pub fn storybook_pastel() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.15, contrast: -0.1, temperature: 0.1, tint: 0.06, saturation: 0.05, fade: 0.25,
            grade_highlights: wheel(40.0, 0.25), grade_shadows: wheel(340.0, 0.15),
            ..t("동화 같은 파스텔", "시네마", "분홍·노랑이 살아있는 대칭 동화 같은 영화 톤")
        },
        &[(RED, 5.0, 0.1, 0.1), (MAGENTA, 0.0, 0.2, 0.1), (YELLOW, -5.0, 0.15, 0.1), (BLUE, -10.0, -0.1, 0.1), (GREEN, -10.0, -0.1, 0.05)],
    )
}

pub fn desert_warm() -> Recipe {
    hsl(
        Recipe {
            temperature: 0.25, contrast: 0.15, highlights: -0.3, saturation: -0.35, fade: 0.1, dehaze: -0.05,
            grade_shadows: wheel(25.0, 0.25), grade_highlights: wheel(42.0, 0.35), vignette: -0.2,
            ..t("사막 웜", "시네마", "모래빛 저채도 웜톤의 대서사 영화 느낌")
        },
        &[(BLUE, 20.0, -0.5, 0.0), (GREEN, -20.0, -0.5, 0.0), (ORANGE, 0.0, 0.1, 0.0)],
    )
}

pub fn melancholy_cyan() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.1, contrast: 0.1, temperature: -0.2, tint: -0.05, saturation: -0.3, fade: 0.2,
            grade_shadows: wheel(190.0, 0.45), grade_highlights: wheel(180.0, 0.15), vignette: -0.2,
            ..t("멜랑콜리 시안", "시네마", "쓸쓸한 청록빛 독립영화 톤")
        },
        &[(ORANGE, 0.0, -0.15, 0.0), (RED, 0.0, -0.2, 0.0), (GREEN, 20.0, -0.2, 0.0)],
    )
}

// ============================================================ 인물

pub fn soft_portrait() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.15, contrast: -0.1, highlights: -0.2, shadows: 0.25, clarity: -0.15, texture: -0.2,
            temperature: 0.06, vibrance: 0.1, skin_protect: 0.3,
            ..t("인물 화사하게", "인물", "밝고 매끈한 피부, 부드러운 대비")
        },
        &[(ORANGE, 0.0, -0.1, 0.18), (RED, 3.0, -0.05, 0.05)],
    )
}

pub fn warm_skin() -> Recipe {
    hsl(
        Recipe {
            temperature: 0.12, tint: 0.04, contrast: 0.05, shadows: 0.15, highlights: -0.15, vibrance: 0.1,
            texture: -0.1, skin_protect: 0.2,
            grade_highlights: wheel(35.0, 0.2),
            ..t("따뜻한 피부", "인물", "혈색 도는 건강한 피부톤")
        },
        &[(ORANGE, -3.0, 0.05, 0.1), (RED, 4.0, 0.0, 0.05), (YELLOW, -8.0, -0.1, 0.0)],
    )
}

pub fn portrait_film() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.1, contrast: -0.15, highlights: -0.3, shadows: 0.2, saturation: -0.12, fade: 0.25,
            temperature: 0.06, grain: 0.18, bloom: 0.1, texture: -0.15,
            grade_shadows: wheel(195.0, 0.2), grade_highlights: wheel(40.0, 0.2),
            curve: film_curve(0.04, 0.97, 0.015),
            ..t("인물 필름 소프트", "인물", "필름 카메라로 찍은 듯한 부드러운 인물")
        },
        &[(ORANGE, 0.0, -0.05, 0.12), (GREEN, 20.0, -0.35, 0.0), (BLUE, -5.0, -0.2, 0.05)],
    )
}

pub fn portrait_chic() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.2, highlights: -0.2, temperature: -0.08, saturation: -0.3, clarity: 0.08, skin_protect: 0.3,
            grade_shadows: wheel(215.0, 0.25), vignette: -0.2,
            ..t("인물 시크", "인물", "차갑고 절제된 패션 화보 톤")
        },
        &[(ORANGE, 0.0, -0.1, 0.05), (RED, 0.0, -0.15, 0.0)],
    )
}

pub fn beauty_highkey() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.45, contrast: -0.15, highlights: -0.25, shadows: 0.35, whites: 0.1, blacks: 0.1,
            clarity: -0.2, texture: -0.3, saturation: -0.05, tint: 0.03, bloom: 0.15, skin_protect: 0.2,
            ..t("뷰티 하이키", "인물", "환하게 날린 밝은 배경과 깨끗한 피부")
        },
        &[(ORANGE, 0.0, -0.15, 0.2), (RED, 0.0, -0.05, 0.1)],
    )
}

// ============================================================ 풍경

pub fn landscape() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.15, highlights: -0.45, shadows: 0.35, dehaze: 0.2, clarity: 0.2, texture: 0.2,
            vibrance: 0.35, sharpen: 0.25,
            ..t("풍경 강조", "풍경", "하늘과 그림자 디테일을 살린 선명한 풍경")
        },
        &[(BLUE, 0.0, 0.15, -0.15), (GREEN, -5.0, 0.1, 0.0)],
    )
}

pub fn deep_sky() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.15, highlights: -0.35, dehaze: 0.15, vibrance: 0.2, temperature: -0.05,
            ..t("깊은 하늘", "풍경", "짙고 깊은 파란 하늘, 또렷한 구름")
        },
        &[(BLUE, -5.0, 0.3, -0.35), (AQUA, -5.0, 0.15, -0.15)],
    )
}

pub fn forest_mood() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.15, contrast: 0.15, highlights: -0.3, saturation: -0.1, temperature: 0.05, fade: 0.1,
            vignette: -0.3, clarity: 0.1,
            grade_shadows: wheel(160.0, 0.25), grade_highlights: wheel(50.0, 0.2),
            ..t("숲 무드", "풍경", "깊고 어두운 올리브 그린의 숲")
        },
        &[(GREEN, -15.0, -0.3, -0.25), (YELLOW, -15.0, -0.15, -0.1), (AQUA, -10.0, -0.3, -0.15)],
    )
}

pub fn ocean_fresh() -> Recipe {
    hsl(
        Recipe {
            exposure: 0.1, contrast: 0.15, highlights: -0.25, temperature: -0.1, vibrance: 0.3, dehaze: 0.1,
            clarity: 0.1,
            ..t("바다 청량", "풍경", "투명한 에메랄드 바다와 맑은 하늘")
        },
        &[(AQUA, -15.0, 0.35, 0.05), (BLUE, -5.0, 0.2, -0.1), (YELLOW, -5.0, -0.1, 0.1)],
    )
}

pub fn misty_morning() -> Recipe {
    Recipe {
        exposure: 0.2, contrast: -0.25, dehaze: -0.2, saturation: -0.2, temperature: -0.05, fade: 0.3,
        bloom: 0.2, clarity: -0.15,
        grade_highlights: wheel(45.0, 0.15), grade_shadows: wheel(200.0, 0.2),
        ..t("안개 낀 아침", "풍경", "옅은 안개와 부드러운 아침 빛")
    }
}

// ============================================================ 야경

pub fn night_city() -> Recipe {
    hsl(
        Recipe {
            contrast: 0.2, highlights: -0.3, blacks: -0.1, temperature: -0.15, tint: 0.1, vibrance: 0.25,
            clarity: 0.1, noise_reduction: 0.2, color_noise_reduction: 0.4,
            grade_shadows: wheel(230.0, 0.4), grade_highlights: wheel(320.0, 0.25),
            ..t("야경 네온", "야경", "푸른 밤과 분홍 네온")
        },
        &[(AQUA, 10.0, 0.2, 0.0), (YELLOW, -10.0, 0.0, 0.0), (MAGENTA, 0.0, 0.2, 0.05)],
    )
}

pub fn night_cinema() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.1, contrast: 0.2, highlights: -0.35, temperature: -0.1, saturation: -0.1,
            halation: 0.3, bloom: 0.15, grain: 0.15, color_noise_reduction: 0.4,
            grade_shadows: wheel(195.0, 0.5), grade_highlights: wheel(35.0, 0.35),
            ..t("야경 시네마", "야경", "청록 밤과 주황 가로등, 빛 번짐")
        },
        &[(ORANGE, -5.0, 0.15, 0.05), (YELLOW, -20.0, 0.0, 0.0), (BLUE, -15.0, 0.1, -0.1)],
    )
}

pub fn neon_noir() -> Recipe {
    hsl(
        Recipe {
            exposure: -0.2, contrast: 0.35, blacks: -0.2, saturation: 0.15, tint: 0.15, bloom: 0.3,
            vignette: -0.35, color_noise_reduction: 0.4,
            grade_shadows: wheel(250.0, 0.5), grade_highlights: wheel(310.0, 0.3),
            ..t("네온 누아르", "야경", "짙은 어둠 속 보라·마젠타 네온")
        },
        &[(MAGENTA, 0.0, 0.3, 0.1), (PURPLE, 0.0, 0.3, 0.05), (AQUA, 10.0, 0.25, 0.05)],
    )
}

// ============================================================ 흑백

pub fn bw_classic() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.3, 0.55, 0.15), contrast: 0.15, grain: 0.15,
        ..t("흑백 클래식", "흑백", "균형 잡힌 기본 흑백")
    }
}

pub fn bw_contrast() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.6, 0.45, -0.05), contrast: 0.5, blacks: -0.2, whites: 0.15,
        clarity: 0.3, vignette: -0.3,
        ..t("흑백 하이콘트라스트", "흑백", "빨강 필터 느낌의 강렬한 흑백, 하늘이 어두워짐")
    }
}

pub fn bw_soft() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.35, 0.5, 0.15), contrast: -0.2, fade: 0.35, shadows: 0.2,
        highlights: -0.2, grade_shadows: wheel(30.0, 0.1),
        ..t("흑백 소프트 매트", "흑백", "부드럽고 은은한 매트 흑백")
    }
}

pub fn bw_grain() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.4, 0.5, 0.1), contrast: 0.35, clarity: 0.2,
        grain: 0.55, grain_size: 0.55, blacks: -0.1, vignette: -0.2,
        curve: vec![(0.0, 0.02), (0.25, 0.2), (0.5, 0.5), (0.75, 0.8), (1.0, 0.98)],
        ..t("흑백 필름 그레인", "흑백", "거친 입자감의 고전 흑백 필름")
    }
}

pub fn bw_selenium() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.3, 0.55, 0.15), contrast: 0.25, grain: 0.15,
        grade_shadows: wheel(230.0, 0.35), grade_highlights: wheel(45.0, 0.08),
        ..t("셀레늄 톤", "흑백", "그림자에 차가운 보랏빛이 도는 인화지 톤")
    }
}

pub fn sepia() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.35, 0.5, 0.15), contrast: 0.1, fade: 0.25, grain: 0.25,
        vignette: -0.3,
        grade_shadows: wheel(28.0, 0.5), grade_midtones: wheel(35.0, 0.4), grade_highlights: wheel(45.0, 0.3),
        ..t("세피아", "흑백", "갈색으로 물든 오래된 사진")
    }
}

// ============================================================ 특수

/// Color-infrared (Aerochrome-like) look: foliage turns red/magenta and glows,
/// skies deepen, other hues (skin, clothing) stay close to the original.
/// Implemented as a hue-selective 3D LUT so it never touches resolution.
pub fn infrared() -> Recipe {
    use crate::color::{hsl_to_rgb, rgb_to_hsl, smoothstep};
    let lut = crate::lut::Lut3d::from_fn(33, |c| {
        let mut hsl = rgb_to_hsl(c);
        let h = hsl[0];
        let foliage = smoothstep(55.0, 85.0, h) * (1.0 - smoothstep(160.0, 185.0, h));
        let sky = smoothstep(185.0, 205.0, h) * (1.0 - smoothstep(245.0, 265.0, h));
        let s_w = smoothstep(0.05, 0.25, hsl[1]);
        let f = foliage * s_w;
        let k = sky * s_w;
        if f > 0.0 {
            let mut d = 350.0 - h;
            if d < -180.0 { d += 360.0; }
            if d > 180.0 { d -= 360.0; }
            hsl[0] = (h + d * f).rem_euclid(360.0);
            hsl[1] = (hsl[1] * (1.0 + 0.4 * f)).min(1.0);
            hsl[2] = (hsl[2] + 0.12 * f * (1.0 - hsl[2])).min(1.0);
        }
        if k > 0.0 {
            hsl[0] -= 10.0 * k;
            hsl[2] *= 1.0 - 0.25 * k;
            hsl[1] = (hsl[1] * (1.0 + 0.2 * k)).min(1.0);
        }
        let warm = smoothstep(0.0, 15.0, h) * (1.0 - smoothstep(40.0, 55.0, h)) * s_w;
        hsl[0] += 6.0 * warm;
        if f == 0.0 && k == 0.0 && warm == 0.0 { return c; }
        hsl_to_rgb(hsl)
    });
    Recipe {
        contrast: 0.15, highlights: -0.1, vibrance: 0.1, lut: Some(lut), lut_strength: 1.0, skin_protect: 0.8,
        ..t("적외선", "특수", "나뭇잎이 붉게 변하는 컬러 적외선 필름")
    }
}

pub fn infrared_bw() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.15, 1.25, -0.4), contrast: 0.3, highlights: -0.15,
        blacks: -0.1, bloom: 0.35, grain: 0.2,
        ..t("적외선 흑백", "특수", "하얗게 빛나는 나뭇잎과 검은 하늘")
    }
}

/// Direct on-camera flash look: bright hard-lit subject, dark falloff, crisp cool light.
pub fn flash() -> Recipe {
    Recipe {
        exposure: 0.25, contrast: 0.35, highlights: 0.2, shadows: -0.35, blacks: -0.15, temperature: -0.08,
        clarity: 0.15, sharpen: 0.3, vignette: -0.6, saturation: 0.05,
        ..t("플래시", "특수", "직광 플래시를 터뜨린 듯한 강한 대비와 어두운 주변부")
    }
}

pub fn cross_process() -> Recipe {
    Recipe {
        contrast: 0.2, saturation: 0.15, fade: 0.1,
        curve_r: vec![(0.0, 0.0), (0.25, 0.18), (0.75, 0.85), (1.0, 1.0)],
        curve_g: vec![(0.0, 0.0), (0.25, 0.22), (0.75, 0.82), (1.0, 1.0)],
        curve_b: vec![(0.0, 0.15), (0.5, 0.5), (1.0, 0.82)],
        ..t("크로스 프로세스", "특수", "잘못 현상한 필름처럼 노랑·초록으로 튀는 색")
    }
}

pub fn duotone_blue() -> Recipe {
    Recipe {
        monochrome: true, channel_mixer: mono_mix(0.3, 0.55, 0.15), contrast: 0.2,
        grade_shadows: wheel(225.0, 0.9), grade_midtones: wheel(210.0, 0.35), grade_highlights: wheel(45.0, 0.25),
        ..t("듀오톤 블루", "특수", "남색과 크림색 두 가지 색만 쓰는 포스터 톤")
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn presets_roundtrip_json() {
        for p in super::all() {
            let back = crate::Recipe::from_json(&p.to_json()).unwrap();
            assert_eq!(back, p);
        }
    }

    #[test]
    fn names_unique_and_suggestions_resolve() {
        let all = super::all();
        let mut names: Vec<_> = all.iter().map(|r| r.name.clone()).collect();
        names.sort();
        let n = names.len();
        names.dedup();
        assert_eq!(n, names.len(), "duplicate template names");
        assert!(n >= 50, "only {n} templates");
        for r in &all {
            assert!(super::CATEGORIES.contains(&r.category.as_str()), "{} has bad category", r.name);
        }
        use crate::analysis::Scene::*;
        for sc in [Portrait, Landscape, Night, Sunset, General] {
            let s = super::suggestions(sc);
            assert!(s.len() >= 15, "{sc:?} has {} suggestions", s.len());
            for name in s {
                assert!(super::by_name(name).is_some(), "missing {name}");
            }
        }
    }
}
