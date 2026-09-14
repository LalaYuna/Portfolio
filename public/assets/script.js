"use strict";

document.documentElement.classList.add("js");

const legacyPage = document.body.dataset.legacyPage;
if (legacyPage) {
  const workTargets = new Set([
    "campaign",
    "social",
    "barryway",
    "additional-work",
    "petfriends-card-news",
    "data-analysis",
  ]);
  let target = legacyPage === "resume" ? "resume" : legacyPage === "contact" ? "contact" : "projects";
  const requestedHash = window.location.hash.slice(1);
  if (legacyPage === "work" && workTargets.has(requestedHash)) target = requestedHash;
  if (legacyPage === "resume" && requestedHash === "resume-education") target = "education";
  if (legacyPage === "resume" && requestedHash === "resume-languages") target = "resume";
  window.location.replace("./index.html#" + target);
}

const menuButton = document.querySelector(".menu-toggle");
const navigation = document.querySelector(".site-nav");
const desktop = window.matchMedia("(min-width: 768px)");

function closeMenu(restoreFocus = false) {
  if (!menuButton || !navigation) return;
  menuButton.setAttribute("aria-expanded", "false");
  navigation.classList.remove("is-open");
  if (restoreFocus) menuButton.focus();
}

if (menuButton && navigation) {
  menuButton.addEventListener("click", () => {
    const opening = menuButton.getAttribute("aria-expanded") !== "true";
    menuButton.setAttribute("aria-expanded", String(opening));
    navigation.classList.toggle("is-open", opening);
    if (opening) navigation.querySelector("a")?.focus();
  });
  navigation.addEventListener("click", (event) => {
    if (event.target.closest("a")) closeMenu();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menuButton.getAttribute("aria-expanded") === "true") closeMenu(true);
  });
  desktop.addEventListener("change", () => {
    if (desktop.matches) closeMenu();
  });
}

const sectionLinks = [...document.querySelectorAll("[data-section-link]")];
const observedSections = [...document.querySelectorAll("[data-nav-section]")];

function setCurrentSection(sectionId) {
  sectionLinks.forEach((link) => {
    if (link.dataset.sectionLink === sectionId) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  });
}

if (sectionLinks.length && observedSections.length && "IntersectionObserver" in window) {
  const visibleSections = new Map();
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) visibleSections.set(entry.target.id, entry.boundingClientRect.top);
      else visibleSections.delete(entry.target.id);
    });
    const current = [...visibleSections.entries()].sort((a, b) => Math.abs(a[1]) - Math.abs(b[1]))[0];
    if (current) setCurrentSection(current[0]);
  }, { rootMargin: "-22% 0px -62% 0px", threshold: 0 });
  observedSections.forEach((section) => observer.observe(section));
}

async function copyText(value) {
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(value);
    return;
  }
  const helper = document.createElement("textarea");
  helper.value = value;
  helper.setAttribute("readonly", "");
  helper.style.position = "fixed";
  helper.style.opacity = "0";
  document.body.appendChild(helper);
  helper.select();
  const copied = document.execCommand("copy");
  helper.remove();
  if (!copied) throw new Error("copy failed");
}

const copyStatus = document.querySelector("[data-copy-status]");
document.querySelectorAll("[data-copy-value]").forEach((button) => {
  button.addEventListener("click", async () => {
    try {
      await copyText(button.dataset.copyValue);
      if (copyStatus) copyStatus.textContent = button.dataset.copyLabel + "를 복사했습니다.";
    } catch {
      if (copyStatus) copyStatus.textContent = "복사하지 못했습니다. 표시된 주소를 직접 선택해 복사해 주세요.";
    }
  });
});

const mediaPlayers = [...document.querySelectorAll("video")];
mediaPlayers.forEach((player) => {
  player.addEventListener("play", () => {
    mediaPlayers.forEach((otherPlayer) => {
      if (otherPlayer !== player && !otherPlayer.paused) otherPlayer.pause();
    });
  });
});

document.querySelectorAll("[data-petfriends-carousel]").forEach((carousel) => {
  const track = carousel.querySelector("[data-carousel-track]");
  const viewport = carousel.querySelector("[data-carousel-viewport]");
  const slides = [...carousel.querySelectorAll("[data-carousel-slide]")];
  const previousButton = carousel.querySelector("[data-carousel-prev]");
  const nextButton = carousel.querySelector("[data-carousel-next]");
  const controls = carousel.querySelector("[data-carousel-controls]");
  const status = carousel.querySelector("[data-carousel-status]");
  const dots = [...carousel.querySelectorAll("[data-carousel-dot]")];
  const originalLink = carousel.querySelector("[data-carousel-original]");
  if (!track || !viewport || !slides.length || !previousButton || !nextButton || !controls) return;

  let currentIndex = 0;
  let touchStartX = 0;
  let touchStartY = 0;
  let suppressSlideClick = false;

  function showSlide(requestedIndex) {
    const nextIndex = Math.max(0, Math.min(requestedIndex, slides.length - 1));
    currentIndex = nextIndex;
    track.style.transform = `translateX(-${currentIndex * 100}%)`;
    previousButton.disabled = currentIndex === 0;
    nextButton.disabled = currentIndex === slides.length - 1;
    if (status) status.textContent = `${currentIndex + 1} / ${slides.length}`;

    slides.forEach((slide, index) => {
      const active = index === currentIndex;
      slide.setAttribute("aria-hidden", String(!active));
      slide.querySelectorAll("a, button").forEach((element) => {
        element.tabIndex = active ? 0 : -1;
      });
    });

    dots.forEach((dot, index) => {
      if (index === currentIndex) dot.setAttribute("aria-current", "true");
      else dot.removeAttribute("aria-current");
    });

    const currentImageLink = slides[currentIndex].querySelector("a[href]");
    if (originalLink && currentImageLink) {
      originalLink.setAttribute("href", currentImageLink.getAttribute("href"));
      originalLink.setAttribute("aria-label", `${currentIndex + 1}번째 이미지 원본 보기`);
    }
  }

  previousButton.hidden = false;
  nextButton.hidden = false;
  controls.hidden = false;
  showSlide(0);

  previousButton.addEventListener("click", () => showSlide(currentIndex - 1));
  nextButton.addEventListener("click", () => showSlide(currentIndex + 1));
  dots.forEach((dot) => {
    dot.addEventListener("click", () => showSlide(Number(dot.dataset.carouselDot)));
  });

  carousel.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      showSlide(currentIndex - 1);
    }
    if (event.key === "ArrowRight") {
      event.preventDefault();
      showSlide(currentIndex + 1);
    }
  });

  viewport.addEventListener("touchstart", (event) => {
    const touch = event.changedTouches[0];
    touchStartX = touch.clientX;
    touchStartY = touch.clientY;
    suppressSlideClick = false;
  }, { passive: true });

  viewport.addEventListener("touchend", (event) => {
    const touch = event.changedTouches[0];
    const distanceX = touch.clientX - touchStartX;
    const distanceY = touch.clientY - touchStartY;
    const horizontalSwipe = Math.abs(distanceX) >= 44 && Math.abs(distanceX) > Math.abs(distanceY) * 1.2;
    if (!horizontalSwipe) return;

    suppressSlideClick = true;
    if (distanceX < 0) showSlide(currentIndex + 1);
    else showSlide(currentIndex - 1);
    window.setTimeout(() => { suppressSlideClick = false; }, 300);
  }, { passive: true });

  viewport.addEventListener("click", (event) => {
    if (!suppressSlideClick) return;
    event.preventDefault();
    event.stopPropagation();
    suppressSlideClick = false;
  }, true);
});
