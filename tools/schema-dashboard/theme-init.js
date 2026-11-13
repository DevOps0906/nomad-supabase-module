// 첫 페인트 전에 저장된 테마를 적용한다(깜빡임 방지). system이면 data-theme을 두지 않고 OS 설정을 따른다.
(function () {
  try {
    var q = new URLSearchParams(location.search).get("theme"); // 스크린샷용 임시 지정(저장 안 함)
    var t = q || localStorage.getItem("nomad.theme");
    if (t === "light" || t === "dark") document.documentElement.setAttribute("data-theme", t);
  } catch (e) { /* 저장소 차단 시 system */ }
})();
