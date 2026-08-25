document.documentElement.classList.add("js");

const header = document.querySelector("[data-header]");
const menuButton = document.querySelector("[data-menu-button]");
const navigation = document.querySelector("[data-navigation]");
const navigationLinks = navigation ? [...navigation.querySelectorAll("a[href^='#']")] : [];

const closeMenu = ({ restoreFocus = false } = {}) => {
  if (!menuButton || !navigation) {
    return;
  }

  menuButton.setAttribute("aria-expanded", "false");
  navigation.classList.remove("is-open");
  header?.classList.remove("is-menu-open");
  document.body.classList.remove("menu-open");

  if (restoreFocus) {
    menuButton.focus();
  }
};

const openMenu = () => {
  if (!menuButton || !navigation) {
    return;
  }

  menuButton.setAttribute("aria-expanded", "true");
  navigation.classList.add("is-open");
  header?.classList.add("is-menu-open");
  document.body.classList.add("menu-open");
  navigationLinks[0]?.focus();
};

menuButton?.addEventListener("click", () => {
  const isOpen = menuButton.getAttribute("aria-expanded") === "true";
  if (isOpen) {
    closeMenu();
    return;
  }

  openMenu();
});

navigationLinks.forEach((link) => {
  link.addEventListener("click", () => closeMenu());
});

document.addEventListener("keydown", (event) => {
  const isOpen = menuButton?.getAttribute("aria-expanded") === "true";
  if (event.key === "Escape" && isOpen) {
    closeMenu({ restoreFocus: true });
  }
});

window.addEventListener("resize", () => {
  if (window.innerWidth > 900) {
    closeMenu();
  }
});

const updateHeader = () => {
  header?.classList.toggle("is-scrolled", window.scrollY > 16);
};

updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

document.querySelectorAll("[data-current-year]").forEach((element) => {
  element.textContent = String(new Date().getFullYear());
});

const filterButtons = [...document.querySelectorAll("[data-filter]")];
const projectCards = [...document.querySelectorAll("[data-project-card]")];
const filterStatus = document.querySelector("[data-filter-status]");

const filterProjects = (selectedFilter) => {
  let visibleCount = 0;

  projectCards.forEach((card) => {
    const matchesFilter =
      selectedFilter === "all" || card.dataset.category === selectedFilter;

    card.hidden = !matchesFilter;
    if (matchesFilter) {
      visibleCount += 1;
    }
  });

  filterButtons.forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.filter === selectedFilter));
  });

  if (filterStatus) {
    const selectedButton = filterButtons.find(
      (button) => button.dataset.filter === selectedFilter,
    );
    const selectedLabel = selectedButton?.childNodes[0]?.textContent?.trim() || "선택한 분류";
    filterStatus.textContent = `${selectedLabel} 프로젝트 ${visibleCount}개 표시 중`;
  }
};

filterButtons.forEach((button) => {
  button.addEventListener("click", () => {
    filterProjects(button.dataset.filter || "all");
  });
});

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealElements = [...document.querySelectorAll(".reveal")];

if (reduceMotion || !("IntersectionObserver" in window)) {
  revealElements.forEach((element) => element.classList.add("is-visible"));
} else {
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) {
          return;
        }

        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    {
      rootMargin: "0px 0px -8%",
      threshold: 0.08,
    },
  );

  revealElements.forEach((element) => revealObserver.observe(element));
}

const observedSections = navigationLinks
  .map((link) => {
    const sectionId = link.getAttribute("href")?.slice(1);
    return sectionId ? document.getElementById(sectionId) : null;
  })
  .filter(Boolean);

if ("IntersectionObserver" in window && observedSections.length > 0) {
  const navigationObserver = new IntersectionObserver(
    (entries) => {
      const visibleEntry = entries.find((entry) => entry.isIntersecting);
      if (!visibleEntry) {
        return;
      }

      navigationLinks.forEach((link) => {
        const isCurrent = link.getAttribute("href") === `#${visibleEntry.target.id}`;
        if (isCurrent) {
          link.setAttribute("aria-current", "location");
        } else {
          link.removeAttribute("aria-current");
        }
      });
    },
    {
      rootMargin: "-30% 0px -60%",
      threshold: 0,
    },
  );

  observedSections.forEach((section) => navigationObserver.observe(section));
}
