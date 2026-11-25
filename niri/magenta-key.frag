// Your Wife на Linux: гра (через user://linux_key.gd) малює фон чистим пурпуровим #FF00FF,
// бо Wine губить альфа-канал. Тут вирізаємо цей колір: точна прозорість для будь-якої моделі,
// чорне волосся й одяг лишаються. Краї, змішані з фоном, отримують часткову прозорість,
// а пурпуровий відтінок з них прибирається.
// Плюс тонкий контур навколо силуету («наліпка»), щоб темні моделі не зливалися з темним столом.
uniform float tolerance;      // наскільки «пурпуровий» може бути колір моделі без прозорості (0.3)
uniform float outline_px;     // товщина контуру в пікселях (0 = без контуру)
uniform vec4 outline_color;   // колір контуру RGBA

float coverage(vec4 c) {
    float m = clamp(min(c.r, c.b) - c.g, 0.0, 1.0);
    return clamp((1.0 - m) / (1.0 - tolerance), 0.0, 1.0) * c.a;
}

vec4 window_color(vec3 coords_geo, vec3 size_geo) {
    vec4 c = niri_sample(coords_geo);
    float a = coverage(c);
    vec3 rgb = c.rgb - (1.0 - a) * vec3(1.0, 0.0, 1.0);
    float spill = 1.0 - a;
    rgb.r = mix(rgb.r, min(rgb.r, rgb.g + 0.1), spill);
    rgb.b = mix(rgb.b, min(rgb.b, rgb.g + 0.1), spill);
    vec4 fg = vec4(clamp(rgb, 0.0, a), a);

    if (outline_px <= 0.0 || a > 0.99) return fg;
    // контур: найбільше покриття моделлю в колі радіусом outline_px (16 напрямків, 2 кільця)
    vec2 px = outline_px / size_geo.xy;
    float near = 0.0;
    for (int i = 0; i < 16; i++) {
        float ang = float(i) * 0.392699;
        vec2 d = vec2(cos(ang), sin(ang)) * px;
        near = max(near, coverage(niri_sample(coords_geo + vec3(d, 0.0))));
        near = max(near, coverage(niri_sample(coords_geo + vec3(d * 0.5, 0.0))));
    }
    vec4 ol = outline_color * near;              // premultiplied
    return fg + ol * (1.0 - fg.a);               // модель поверх контуру
}
