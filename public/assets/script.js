"use strict";

document.documentElement.classList.add("js");

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
    if (event.key === "Escape" && menuButton.getAttribute("aria-expanded") === "true") {
      closeMenu(true);
    }
  });
  desktop.addEventListener("change", () => {
    if (desktop.matches) closeMenu();
  });
}

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const revealElements = [...document.querySelectorAll("[data-reveal]")];
if ("IntersectionObserver" in window && !reducedMotion.matches && revealElements.length) {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.remove("reveal-ready");
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.05 });
  revealElements.forEach((element) => {
    if (element.getBoundingClientRect().top > window.innerHeight) {
      element.classList.add("reveal-ready");
    }
    observer.observe(element);
  });
  reducedMotion.addEventListener("change", () => {
    if (reducedMotion.matches) {
      observer.disconnect();
      revealElements.forEach((element) => element.classList.remove("reveal-ready"));
    }
  });
}

function openLinkedProject() {
  const target = document.getElementById(window.location.hash.slice(1));
  const details = target?.querySelector(".case-study");
  if (details) details.open = true;
}
openLinkedProject();
window.addEventListener("hashchange", openLinkedProject);

const contactForm = document.querySelector("[data-contact-form]");
if (contactForm) {
  const fields = [...contactForm.querySelectorAll("input, textarea")];
  const status = contactForm.querySelector("[data-form-status]");
  const submitButton = contactForm.querySelector('button[type="submit"]');
  const recipient = "yuna12s@naver.com";

  fields.forEach((field) => {
    field.addEventListener("input", () => {
      field.setCustomValidity("");
      status.textContent = "";
    });
  });

  contactForm.addEventListener("submit", (event) => {
    event.preventDefault();
    fields.forEach((field) => {
      field.setCustomValidity("");
      if (!field.value.trim()) {
        field.setCustomValidity("공백을 제외한 내용을 입력해 주세요.");
      } else if (field.maxLength > 0 && field.value.length > field.maxLength) {
        field.setCustomValidity("입력 가능한 길이를 초과했습니다.");
      }
    });
    if (!contactForm.reportValidity()) {
      status.textContent = "입력한 항목을 확인해 주세요.";
      return;
    }

    const senderName = contactForm.elements.namedItem("name").value.trim().replace(/[\r\n]+/g, " ");
    const senderEmail = contactForm.elements.namedItem("email").value.trim();
    const message = contactForm.elements.namedItem("message").value.trim();
    const subject = "[포트폴리오 문의] " + senderName;
    const body = "이름: " + senderName + "\n회신 이메일: " + senderEmail + "\n\n" + message;
    const mailto = "mailto:" + recipient + "?subject=" + encodeURIComponent(subject) + "&body=" + encodeURIComponent(body);

    status.textContent = "메일 앱에서 내용을 확인한 뒤 전송해 주세요. 앱이 열리지 않으면 위 이메일 주소로 직접 작성하실 수 있습니다.";
    window.location.assign(mailto);
  });
  submitButton.disabled = false;
}
