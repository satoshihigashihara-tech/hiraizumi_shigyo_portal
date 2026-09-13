"use client";

import Image from "next/image";
import { useEffect, useRef, useState } from "react";
import styles from "./ShareHouseHero.module.css";

export default function ShareHouseHero() {
  const scene = useRef(null);
  const [ready, setReady] = useState(false);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    let active = true;
    // Decode every frame before starting, including images served from cache.
    Promise.all(Array.from(scene.current.querySelectorAll("img"), (img) => img.decode()))
      .then(() => { if (active) setReady(true); })
      .catch(() => { /* Keep the morning still if a later frame cannot load. */ });

    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        setVisible(true);
        observer.disconnect();
      }
    }, { threshold: 0.25 });
    observer.observe(scene.current);
    return () => { active = false; observer.disconnect(); };
  }, []);

  return <figure className={styles.figure}>
    <div ref={scene} className={styles.scene} data-playing={ready && visible}>
      <Image className={styles.night} src="/landing/share-house-night.webp"
        alt="窓と玄関に明かりがともる平泉町志業シェアハウスの外観と駐車車両"
        fill unoptimized loading="eager" />
      <Image className={styles.morning} src="/landing/share-house-morning.webp"
        alt="" aria-hidden="true" fill unoptimized loading="eager" fetchPriority="high" />
      <Image className={styles.day} src="/landing/share-house-day.webp"
        alt="" aria-hidden="true" fill unoptimized loading="eager" />
    </div>
    <figcaption>実際の写真をもとに、朝・昼・夜を表現したイメージです。</figcaption>
  </figure>;
}
