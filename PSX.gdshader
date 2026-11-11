shader_type spatial;
render_mode depth_test_disabled, skip_vertex_transform, unshaded, cull_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform int resolution_x = 640;
uniform int resolution_y = 640;
uniform int color_bit_depth = 4;
uniform float dither_strength = 0.03;
uniform float jitter_amount = 0.008;
uniform float jitter_speed = 1.2;
uniform float jitter_frequency = 180.0;
uniform float chromatic_aberration_strength : hint_range(0.0, 0.1) = 0.015;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.8;
uniform float vignette_radius : hint_range(0.0, 2.0) = 0.9;
uniform vec2 monitor_pos = vec2(0.5, 0.5);
uniform vec2 monitor_size = vec2(0.0, 0.0);
uniform bool zoomed_in = false;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec2 psx_jitter(vec2 uv) {
    float t = floor(TIME * jitter_speed * 8.0) / 8.0;
    float h_shake = hash(vec2(floor(uv.y * jitter_frequency), t)) - 0.5;
    h_shake *= jitter_amount * 0.75;
    float v_shake = hash(vec2(floor(uv.x * jitter_frequency * 0.4), t)) - 0.5;
    v_shake *= jitter_amount * 0.35;
    float micro = hash(uv * 600.0 + t) - 0.5;
    micro *= jitter_amount * 0.1;
    return uv + vec2(h_shake + micro, v_shake + micro);
}

void vertex() {
    vec2 vert_pos = VERTEX.xy;
    if (length(vert_pos) < 0.99) {
        vec4 offset = PROJECTION_MATRIX * vec4(0.0, 0.0, 1.0, 1.0);
        vert_pos += (offset.xy / offset.w);
    }
    POSITION = vec4(vert_pos, 1.0, 1.0);
}

void fragment() {
    vec2 uv = SCREEN_UV;

    vec2 diff = abs(uv - monitor_pos);
    bool in_monitor = zoomed_in && diff.x < monitor_size.x * 0.5 && diff.y < monitor_size.y * 0.5;

    if (in_monitor) {
        ALBEDO = texture(screen_tex, uv).rgb;
    } else {
        vec2 px = vec2(1.0 / float(resolution_x), 1.0 / float(resolution_y));
        vec2 sample_uv = floor(uv / px) * px + px * 0.5;
        sample_uv = psx_jitter(sample_uv);

        vec3 col;
        if (chromatic_aberration_strength > 0.001) {
            vec2 offset = (sample_uv - 0.5) * chromatic_aberration_strength;
            col.r = texture(screen_tex, sample_uv + offset).r;
            col.g = texture(screen_tex, sample_uv).g;
            col.b = texture(screen_tex, sample_uv - offset).b;
        } else {
            col = texture(screen_tex, sample_uv).rgb;
        }

        float levels = pow(2.0, float(color_bit_depth));
        col = floor(col * levels) / levels;

        if (vignette_strength > 0.0) {
            float dist = distance(uv, vec2(0.5));
            float vignette = 1.0 - vignette_strength * smoothstep(vignette_radius * 0.5, vignette_radius, dist);
            col *= vignette;
        }

        if (dither_strength > 0.0) {
            float noise = hash(uv * 80.0 + floor(TIME * 50.0));
            col += (noise - 0.5) * dither_strength;
        }

        ALBEDO = col;
    }
}