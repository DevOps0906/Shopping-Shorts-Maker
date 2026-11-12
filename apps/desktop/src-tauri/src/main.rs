// 운영 웹 주소를 여는 데스크톱 셸 (ADR-0005).
// 원격 페이지에는 IPC 명령·capability를 주지 않고, 우리 출처 밖 링크는 시스템 브라우저로 연다.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri::webview::NewWindowResponse;
use tauri::{Url, WebviewUrl, WebviewWindowBuilder};

const DEFAULT_WEB_URL: &str = "http://localhost:3000";

/// 실행 시 `APP_WEB_URL` > 빌드 시 `APP_WEB_URL` > 개발 기본값 순서로 고른다.
fn app_web_url() -> Url {
    let raw = std::env::var("APP_WEB_URL")
        .ok()
        .or_else(|| option_env!("APP_WEB_URL").map(str::to_owned))
        .unwrap_or_else(|| DEFAULT_WEB_URL.to_owned());
    let url = Url::parse(&raw).expect("APP_WEB_URL은 http(s) 절대 주소여야 합니다");
    assert!(
        matches!(url.scheme(), "http" | "https"),
        "APP_WEB_URL은 http(s) 절대 주소여야 합니다"
    );
    url
}

fn open_external(url: &Url) {
    if matches!(url.scheme(), "http" | "https" | "mailto") {
        let _ = tauri_plugin_opener::open_url(url.as_str(), None::<&str>);
    }
}

fn main() {
    let web_url = app_web_url();
    let origin = web_url.origin();

    tauri::Builder::default()
        .setup(move |app| {
            let nav_origin = origin.clone();
            let popup_origin = origin.clone();
            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(web_url.clone()))
                .title("Shopping Shorts Maker")
                .inner_size(1280.0, 800.0)
                .min_inner_size(1200.0, 720.0)
                .on_navigation(move |url| {
                    if url.origin() == nav_origin || url.scheme() == "about" {
                        return true;
                    }
                    open_external(url);
                    false
                })
                .on_new_window(move |url, _features| {
                    // 새 창은 만들지 않는다. 외부 주소는 시스템 브라우저로.
                    if url.origin() != popup_origin {
                        open_external(&url);
                    }
                    NewWindowResponse::Deny
                })
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("데스크톱 셸 실행 실패");
}
