#include <metal_stdlib>
using namespace metal;

struct Vertex { packed_float3 position; packed_float3 normal; packed_float2 uv; packed_float3 bend; float part; };
struct Background { float4 position [[position]]; float2 uv; };
vertex Background backgroundVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2.0 - 1.0, 0.999, 1.0), p};
}
struct TankUniforms { float4x4 model; float4x4 viewProjection; float4 options; float4 water; float4 camera; float4 detail; float4 pivot; float4 motion; float4x4 lightProjection; };
struct TankRaster { float4 position [[position]]; float3 world; float3 normal; float2 uv; float sand [[flat]]; float eye [[flat]]; };

vertex TankRaster tankVertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]], constant TankUniforms &u [[buffer(1)]]) {
    Vertex v = vertices[id]; float3 p = float3(v.position), normal = float3(v.normal);
    float t = u.options.x, phase = u.water.x;
    if (u.options.z < 0.5) {
        if (v.part > 4.5) {
            p += float3(v.bend) * sin(t * u.water.y * 8.0 + phase) * 0.10;
            p.z += smoothstep(0.0, 0.5, p.x) * sin(t * u.water.y * 8.0 + phase - p.x * 6.0) * 0.018;
        } else if (v.part > 0.5) {
            p.z += sign(p.z) * abs(p.z) * sin(t * 5.0 + phase + v.part) * 0.14;
        }
    } else if (u.detail.z > 0.5) {
        float kind = u.motion.x, amplitude = u.motion.y, frequency = u.motion.z, seed = u.motion.w;
        float h = clamp((p.y - u.pivot.y) / max(u.pivot.w, 0.05), 0.0, 1.0);
        if (kind > 0.5 && kind < 1.5) {
            // Roots stay fixed. Curvature and phase grow along each branch.
            float wave = t * frequency + seed + h * 1.9;
            float branch = sin(p.x * 3.2 + p.z * 2.1 + seed);
            float w = h * h;
            p.x += amplitude * w * (sin(wave) + 0.16 * h * sin(t * 1.1 + branch * 2.0));
            p.z += amplitude * w * 0.46 * cos(wave * 0.91 + branch);
            float dxdy = amplitude * (2.0 * h * sin(wave) + w * 1.9 * cos(wave)) / max(u.pivot.w, 0.05);
            float dzdy = amplitude * 0.46 * (2.0 * h * cos(wave * 0.91 + branch) - w * 1.73 * sin(wave * 0.91 + branch)) / max(u.pivot.w, 0.05);
            normal.y -= normal.x * dxdy + normal.z * dzdy;
        } else if (kind > 1.5 && kind < 2.5) {
            float openness = 0.5 - 0.5 * cos(t * frequency + seed);
            float angle = amplitude * openness;
            float2 q = p.xy - u.pivot.xy;
            p.xy = u.pivot.xy + float2(cos(angle) * q.x - sin(angle) * q.y, sin(angle) * q.x + cos(angle) * q.y);
            normal.xy = float2(cos(angle) * normal.x - sin(angle) * normal.y, sin(angle) * normal.x + cos(angle) * normal.y);
        } else if (kind > 2.5 && kind < 3.5) {
            float openness = 0.5 - 0.5 * cos(t * frequency + seed);
            p += float3(v.bend) * openness;
        } else if (kind > 3.5 && kind < 4.5) {
            float pulse = 0.5 + 0.5 * sin(t * frequency + seed);
            p.xz = u.pivot.xz + (p.xz - u.pivot.xz) * (1.0 - 0.07 * h * pulse);
            p.y -= h * u.pivot.w * 0.055 * pulse;
            p.x += amplitude * h * h * sin(t * 0.8 + p.y * 4.0);
        } else if (kind > 4.5 && kind < 5.5) {
            // Original closed -> open mouth target; neck motion fades to zero
            // at the hidden tail so the animal remains seated in its cave.
            float head = clamp((u.pivot.x - p.x) / u.pivot.w, 0.0, 1.0);
            float breath = 0.5 - 0.5 * cos(t * frequency + seed);
            p += float3(v.bend) * breath;
            // Opening the original jaw target needs clearance from the cave lip.
            // The neck leans forward with the breath; the hidden tail stays fixed.
            float neck = head * head;
            p.z += neck * (0.10 + 0.24 * breath + amplitude * 0.25 * sin(t * 0.32 + seed));
            p.y += neck * 0.045 * breath;
            p.x -= amplitude * 0.15 * neck * (0.5 - 0.5 * cos(t * 0.22));
            p.y += 0.008 * head * sin(t * frequency + seed);
        } else if (kind > 5.5) {
            // A bounded, very slow sand route. Root vertices of all five arms
            // share the same translation; only their tips flex independently.
            float radial = smoothstep(0.08, 0.45, length(p.xz - u.pivot.xz));
            p.y += amplitude * radial * (0.5 + 0.5 * sin(t * frequency + seed));
            p.x += 0.25 * sin(t * 0.012);
            p.z += 0.15 * sin(t * 0.008);
        }
    }
    float4 world = u.model * float4(p, 1.0);
    float3 squaredScale=float3(dot(u.model[0].xyz,u.model[0].xyz),dot(u.model[1].xyz,u.model[1].xyz),dot(u.model[2].xyz,u.model[2].xyz));
    return {u.viewProjection * world, world.xyz, (u.model * float4(normal/max(squaredScale,float3(0.001)), 0)).xyz, float2(v.uv), u.detail.x < -0.5 ? 1.0 : 0.0, v.part < 0.5 && u.options.z < 0.5 ? 1.0 : 0.0};
}

fragment void tankShadow(TankRaster r [[stage_in]], texture2d<float> skin [[texture(0)]]) {
    constexpr sampler s(address::repeat, filter::linear, mip_filter::linear);
    if (skin.sample(s, r.uv).a < 0.35) discard_fragment();
}

float shadowVisibility(float3 world, float3 normal, constant TankUniforms &u, depth2d<float> map, bool sand) {
    if (u.detail.w < 1.5) return 1.0;
    float4 clip = u.lightProjection * float4(world, 1);
    float3 ndc = clip.xyz / clip.w;
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z < 0.0 || ndc.z > 1.0) return 1.0;
    constexpr sampler comparison(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
    float slope = 1.0 - max(dot(normal, normalize(float3(-9, 16, 10))), 0.0);
    float depth = ndc.z - (0.00022 + slope * 0.0007);
    float visibility = 0;
    int radius=sand ? 2 : 1;
    float spacing=sand ? 8.0 : 2.3;
    for (int y=-radius; y<=radius; y++) for (int x=-radius; x<=radius; x++)
        visibility+=map.sample_compare(comparison,uv+float2(x,y)*spacing/float2(map.get_width(),map.get_height()),depth);
    return visibility/float((radius*2+1)*(radius*2+1));
}

float3 waterBacking(float height, constant TankUniforms &u) {
    // Bright display-aquarium backing: clear sky blue above, soft turquoise below.
    float3 bottom=u.water.z>0.5 ? float3(0.045,0.20,0.36) : float3(0.042,0.20,0.18);
    float3 top=u.water.z>0.5 ? float3(0.17,0.40,0.82) : float3(0.18,0.44,0.86);
    return mix(bottom,top,smoothstep(0.0,1.0,height));
}
float3 immerseInWater(float3 rgb, float3 world, constant TankUniforms &u) {
    // Clear foreground; only the most distant surfaces have a trace of haze.
    float distance=max(0.0,length(u.camera.xyz-world)-24.0);
    float haze=min(0.12,1.0-exp(-distance*0.012));
    return mix(rgb,waterBacking(clamp((world.y+2.3)/7.0,0.0,1.0),u),haze);
}

fragment float4 tankFragment(TankRaster r [[stage_in]], constant TankUniforms &u [[buffer(1)]], texture2d<float> skin [[texture(0)]], texture2d<float> caustic [[texture(1)]], depth2d<float> shadowMap [[texture(2)]]) {
    constexpr sampler s(address::repeat, filter::linear, mip_filter::linear);
    float4 color = skin.sample(s, r.uv);
    // Alpha cutout writes correct reef depth; very low alpha fringe is removed.
    if (color.a < 0.20) discard_fragment();
    float3 n = length(r.normal) > 0.01 ? normalize(r.normal) : normalize(cross(dfdx(r.world), dfdy(r.world)));
    bool sand = r.sand > 0.5;
    float3 eye = normalize(u.camera.xyz - r.world);
    if (dot(n, eye) < 0) n = -n;
    float diffuse = max(dot(n, normalize(float3(-0.3, 0.85, 0.5))), 0.0);
    bool fish = u.options.z < 0.5;
    // The reef atlases already contain shading. A broad water/sky fill preserves
    // those shadows instead of multiplying them by another dark ambient term.
    float sky = 0.5 + 0.5 * n.y;
    float light = fish ? 0.68 + diffuse * 0.43 : 0.86 + diffuse * 0.34;
    float3 fill = mix(float3(0.88, 0.95, 0.97), float3(0.96, 1.0, 1.0), sky);
    float3 rgb = color.rgb * light * fill;
    float visibility = shadowVisibility(r.world,n,u,shadowMap,sand);
    if (u.detail.w > 0.5) {
        float3 key = normalize(float3(-9, 16, 10));
        float keyDiffuse = max(dot(n, key), 0.0);
        // Bright water stays bright, while directional light describes volume.
        float ambient = fish ? 0.58 : 0.55 + sky * 0.16;
        float fishDiffuse=max(dot(n,normalize(float3(-0.30,0.45,0.84))),0.0)*0.62;
        float direct = fish ? fishDiffuse*(0.80+0.20*visibility) : 0.65*keyDiffuse*(sand ? 0.35+0.65*visibility : visibility);
        float3 ambientColor = mix(float3(0.84, 0.89, 0.95), float3(0.96, 0.98, 1.0), sky);
        rgb = fish ? color.rgb*(ambient+direct) : color.rgb*(ambient*ambientColor+direct*float3(1.0,0.99,0.96));
        // Broad, restrained wet sheen follows the actual interpolated normals.
        float3 halfVector = normalize(key + eye);
        float fresnel = 0.025 + 0.10 * pow(1.0 - max(dot(n, eye), 0.0), 5.0);
        float specular = pow(max(dot(n, halfVector), 0.0), fish ? (r.eye > 0.5 ? 64.0 : 42.0) : 20.0);
        rgb += float3(0.83, 0.95, 1.0) * specular * (fish ? (r.eye > 0.5 ? 0.40 : 0.025 + fresnel*0.15) : 0.018) * visibility * smoothstep(0.0, 0.2, keyDiffuse);
    }
    if (u.options.w > 0.5) {
        float t = u.options.x;
        float2 warp=float2(sin(r.world.z*0.63+t*0.11),cos(r.world.x*0.51-t*0.09))*0.07;
        float2 projected=r.world.xz*0.29+r.world.y*float2(0.045,0.025)+warp;
        float a=caustic.sample(s, projected+float2(t*0.018,t*0.011)).r;
        float b=caustic.sample(s, projected*1.19+float2(-t*0.013,t*0.008)+0.37).r;
        float pattern=smoothstep(0.009,0.073,max(a,b*0.82));
        float topFacing=0.22+0.78*max(0.0,n.y);
        float strength=fish ? 0.105 : sand ? 0.18 : 0.13;
        // Caustics follow the same projected light field across fish and reef.
        // Shadowed surfaces and vertical faces receive much less moving light.
        if (fish) {
            // Original Fish.frag adds two lightplay samples, weighted by vertex
            // diffuse, rather than multiplying the skin by a brightening mask.
            float3 lightplayCoord=r.world*float3(0.29,0.25,0.29)+float3(t*0.018,t*0.011,-t*0.013);
            float3 lightplay=caustic.sample(s,lightplayCoord.xy).rgb+caustic.sample(s,lightplayCoord.zx).rgb;
            float diffuse=max(dot(n,normalize(float3(-0.30,0.45,0.84))),0.0)*0.62;
            rgb+=lightplay*diffuse*0.85;
        } else {
            rgb *= 0.985 + pattern*strength*topFacing*visibility;
        }
    }
    // Gentle highlight compression keeps pale coral tissue from clipping.
    rgb=rgb/(1.0+max(float3(0),rgb-0.75)*0.18);
    rgb=immerseInWater(rgb,r.world,u);
    return float4(rgb, fish ? color.a : 1.0);
}

fragment float4 tankBackground(Background r [[stage_in]], constant TankUniforms &u [[buffer(1)]]) {
    return float4(waterBacking(r.uv.y,u),1);
}

// Discrete transparent bubbles, rather than a repeated sheet of dense foam.
struct BubbleColumnRaster { float4 position [[position]]; float2 uv; float3 world; float fade; };
float bubbleHash(float seed) { return fract(sin(seed*127.1+311.7)*43758.5453); }
vertex BubbleColumnRaster bubbleColumnVertex(uint id [[vertex_id]], uint instance [[instance_id]], constant TankUniforms &u [[buffer(1)]]) {
    const float2 corners[]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    float2 uv=corners[id];
    float seed=float(instance)+1.0, t=u.options.x;
    float speed=mix(0.24,0.40,bubbleHash(seed+7.0));
    float height=fract(bubbleHash(seed)+t*speed/8.25);
    float y=mix(-2.25,6.0,height);
    float spread=mix(0.11,0.35,height);
    float x=u.camera.x+0.5+(bubbleHash(seed+3.0)*2.0-1.0)*spread;
    x+=sin(t*0.65+seed*2.4+y)*0.035;
    float z=-1.4+(bubbleHash(seed+11.0)-0.5)*0.45;
    // Most bubbles are tiny; a few larger ones provide recognizable glassy rims.
    float radius=mix(0.016,0.046,pow(bubbleHash(seed+19.0),2.0))*(0.88+height*0.22);
    float3 world=float3(x,y,z)+float3(uv*float2(radius,radius*0.94),0);
    float fade=smoothstep(0.0,0.035,height)*(1.0-smoothstep(0.97,1.0,height));
    return {u.viewProjection*float4(world,1),uv,world,fade};
}
fragment float4 bubbleColumnFragment(BubbleColumnRaster r [[stage_in]], constant TankUniforms &u [[buffer(1)]]) {
    float d=length(r.uv);
    float aa=max(fwidth(d),0.025);
    float coverage=1.0-smoothstep(1.0-aa,1.0+aa,d);
    if (coverage<0.001) discard_fragment();
    float rim=exp(-pow((d-0.80)/0.13,2.0));
    float glint=exp(-dot(r.uv-float2(-0.32,0.49),r.uv-float2(-0.32,0.49))*32.0);
    float lower=exp(-dot(r.uv-float2(0.23,-0.65),r.uv-float2(0.23,-0.65))*20.0);
    float litSide=0.5+0.5*dot(normalize(r.uv+0.0001),normalize(float2(-0.6,0.8)));
    float3 rgb=mix(float3(0.16,0.35,0.40),float3(0.78,0.92,0.97),litSide);
    rgb=mix(rgb,float3(0.95,0.99,1.0),min(1.0,glint+lower*0.35));
    float alpha=(rim*0.36+glint*0.72+lower*0.18)*coverage*r.fade;
    return float4(immerseInWater(rgb,r.world,u),min(alpha,0.82));
}
struct WaterParticle { float4 position [[position]]; float2 uv; };
vertex WaterParticle particleVertex(uint id [[vertex_id]], uint instance [[instance_id]], constant TankUniforms &u [[buffer(1)]]) {
    const float2 corners[]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    float seed=float(instance)+80;
    float y=fract(seed*0.173+u.options.x*0.003)*9.0-3.6;
    float x=u.camera.x+fract(seed*0.618)*15.0-7.5+sin(u.options.x*0.65+seed+y)*0.04;
    float z=fract(seed*0.381)*6.0-1.5;
    float radius=0.007+fract(seed*0.37)*0.005;
    float2 uv=corners[id];
    return {u.viewProjection*float4(float3(x,y,z)+float3(uv*radius,0),1),uv};
}
fragment float4 particleFragment(WaterParticle r [[stage_in]]) {
    float d=length(r.uv); if (d>1.0) discard_fragment();
    return float4(0.59,0.82,0.86,exp(-d*d*4.0)*0.018);
}

// Original parametric Aurelia study: no downloaded mesh or photographic texture.
struct MoonJellyRaster {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 local;
    float2 uv;
    uint kind [[flat]];
};
float3 moonRotate(float3 p, float tilt, float roll) {
    p = float3(p.x, p.y * cos(tilt) - p.z * sin(tilt), p.y * sin(tilt) + p.z * cos(tilt));
    return float3(p.x * cos(roll) - p.y * sin(roll), p.x * sin(roll) + p.y * cos(roll), p.z);
}
vertex MoonJellyRaster moonJellyVertex(uint id [[vertex_id]], uint instance [[instance_id]], constant TankUniforms &u [[buffer(1)]]) {
    constexpr float pi = 3.14159265359;
    const float2 corners[] = {float2(0,0), float2(1,0), float2(0,1), float2(0,1), float2(1,0), float2(1,1)};
    const float xs[] = {-4.8, 2.7, 0.2, -3.2, 3.4};
    const float sizes[] = {0.86, 0.68, 0.55, 0.59, 0.52};
    const float heights[] = {4.0, 4.05, 3.80, 3.5, 3.85};
    const float depths[] = {-0.8, 1.2, -3.5, 0.2, -2.0};
    const float tilts[] = {0.48, 0.82, 1.02, 0.62, 0.9};
    float seed = float(instance) * 2.39996;
    float t = u.options.x, phase = t * (2.0 + float(instance) * 0.09) + seed;
    // Brief contraction, longer recovery, with a small lag at the margin.
    float squeeze = pow(0.5 + 0.5 * sin(phase), 4.0);
    float radius = 1.0 - 0.15 * squeeze, height = 0.35 + 0.17 * squeeze;
    float2 corner = corners[id % 6];
    uint quad = id / 6, kind = 0;
    float3 p, n = float3(0,1,0);
    float2 uv;
    if (quad < 2 * 48 * 96) {
        bool inner = quad >= 48 * 96;
        quad %= 48 * 96;
        kind = inner ? 3 : 0;
        float r = (float(quad / 96) + corner.y) / 48.0;
        float theta = (float(quad % 96) + corner.x) / 96.0 * 2.0 * pi;
        float scallop = 1.0 + (0.009 * cos(theta * 16.0) + 0.014 * sin(theta * 3.0 + seed)) * pow(r, 5.0);
        p = float3(cos(theta) * r * radius * scallop, height * sqrt(max(0.0, 1.0 - r * r)), sin(theta) * r * radius * scallop);
        p.y -= 0.065 * squeeze * smoothstep(0.75, 1.0, r);
        if (inner) p.y -= 0.045 * pow(max(0.0, 1.0 - r * r), 0.45);
        n = normalize(float3(p.x / (radius * radius), max(0.001, p.y) / (height * height), p.z / (radius * radius)));
        uv = float2(r, theta);
    } else if (quad < 2 * 48 * 96 + 4 * 64 * 16) {
        kind = 1; quad -= 2 * 48 * 96;
        uint arm = quad / (64 * 16), cell = quad % (64 * 16);
        float s = (float(cell / 16) + corner.y) / 64.0;
        float across = (float(cell % 16) + corner.x) / 16.0 * 2.0 - 1.0;
        float theta = float(arm) * pi * 0.5 + pi * 0.25;
        float wave = sin(s * 29.0 - t * 1.5 + seed + float(arm));
        float width = (0.16 + 0.045 * wave) * pow(max(0.0, 1.0 - s), 0.55);
        float spread = 0.10 + 0.16 * s + sin(t * 0.6 - s * 4.0 + seed + float(arm)) * 0.08 * s;
        p = float3(cos(theta) * spread - sin(theta) * across * width, -0.03 - s * (0.72 + float(arm % 2) * 0.14), sin(theta) * spread + cos(theta) * across * width);
        // Broad folds carry finer ruffled edges, rather than a flat zigzag ribbon.
        p.y += sin(s * 36.0 + across * 5.0 - t * 1.3) * 0.035 * sin(s * pi);
        p.z += sin(across * 8.0 + s * 17.0 - t * 0.7) * 0.055 * sin(s * pi);
        n = normalize(float3(0.3 * cos(across * 8.0 + s * 17.0), 0.4, 1.0));
        p.z += wave * 0.035 * abs(across) + sin(t * 0.7 - s * 5.0 + seed) * 0.10 * s * s;
        uv = float2(across, s);
    } else {
        kind = 2; quad -= 2 * 48 * 96 + 4 * 64 * 16;
        uint filament = quad / 8;
        float s = (float(quad % 8) + corner.y) / 8.0;
        float theta = float(filament) / 96.0 * 2.0 * pi;
        float length = 0.16 + 0.10 * (0.5 + 0.5 * sin(float(filament) * 1.72));
        float sway = sin(t * 1.2 - s * 3.0 + theta * 3.0 + seed) * 0.045 * s * s;
        p = float3(cos(theta) * radius + sway, -0.065 * squeeze - s * length, sin(theta) * radius + sway * 0.55);
        p.x += (corner.x * 2.0 - 1.0) * 0.006 * (1.0 - 0.6 * s);
        uv = float2(corner.x, s);
    }
    float3 local = p / float3(radius, 1, radius);
    float roll = sin(t * 0.12 + seed) * 0.14 + (float(instance) - 1.0) * 0.12;
    float tilt = tilts[instance] + sin(t * 0.09 + seed) * 0.12;
    float scale = sizes[instance] * 0.76;
    float y = heights[instance];
    float3 center = float3(u.camera.x + xs[instance] + sin(t * 0.14 + seed) * 0.38, y + sin(t * 0.19 + seed) * 0.28 + sin(phase - 0.6) * 0.045, depths[instance] + sin(t * 0.1 + seed) * 0.12);
    float3 world = moonRotate(p, tilt, roll) * scale + center;
    return {u.viewProjection * float4(world, 1), world, moonRotate(n, tilt, roll), local, uv, kind};
}
fragment float4 moonJellyFragment(MoonJellyRaster r [[stage_in]], constant TankUniforms &u [[buffer(1)]]) {
    float3 view = normalize(u.camera.xyz - r.world);
    if (r.kind == 0 || r.kind == 3) {
        float facing = abs(dot(normalize(r.normal), view));
        float fresnel = pow(1.0 - facing, 2.2);
        float radius = r.uv.x, angle = r.uv.y;
        float tissue = 0.5 + 0.5 * sin(angle * 31.0 + sin(radius * 43.0) * 2.0);
        // Faint irregular canals are embedded in tissue, not a wireframe overlay.
        float branches = sin(radius * 25.0 + sin(angle * 8.0)) * 0.6;
        float canals = pow(0.5 + 0.5 * cos(angle * 96.0 + branches), 24.0)
            * smoothstep(0.55, 0.95, radius) * 0.018;
        float rim = exp(-pow((radius - 0.975) / 0.027, 2.0));
        float organs = 0, organSoft = 0;
        for (uint i = 0; i < 4; ++i) {
            float theta = float(i) * 1.570796327 + 0.07 * sin(float(i) * 2.7);
            float2 center = float2(cos(theta), sin(theta)) * (0.21 + 0.012 * sin(float(i) * 1.8));
            float2 q = r.local.xz - center;
            float distortion = 1.0 + 0.10 * sin(atan2(q.y,q.x) * 3.0 + float(i));
            float d = length(q * float2(1.0,1.12)) * distortion;
            float opening = smoothstep(0.3, 0.9, dot(q, normalize(-center)) / max(0.001, length(q)));
            organs += exp(-pow((d - 0.113) / 0.044, 2.0)) * (1.0 - opening * 0.78);
            organSoft += exp(-pow(d / 0.16, 2.0));
        }
        float sheen = pow(max(0.0, dot(reflect(-normalize(float3(-0.3,0.8,1.0)), normalize(r.normal)), view)), 20.0);
        float thickness = 0.035 + 0.028 * pow(max(0.0, 1.0 - radius), 2.0);
        float alpha = thickness + fresnel * 0.14 + rim * 0.03 + canals
            + organs * (0.11 + tissue * 0.025) + organSoft * 0.018;
        float3 color = mix(float3(0.48,0.62,0.71), float3(0.65,0.61,0.70), saturate(organs * 0.45));
        color += sheen * 0.11 + rim * 0.05;
        if (r.kind == 3) alpha *= 0.40;
        return float4(immerseInWater(color,r.world,u), min(0.36, alpha)*0.82);
    }
    if (r.kind == 1) {
        float softEdge = 1.0 - smoothstep(0.55, 1.0, abs(r.uv.x));
        float folds = 0.5 + 0.5 * sin(r.uv.y * 48.0 + r.uv.x * 12.0);
        float lighting = 0.6 + 0.4 * abs(dot(normalize(r.normal), normalize(float3(-0.3,0.8,1.0))));
        return float4(immerseInWater(float3(0.78,0.79,0.83) * lighting,r.world,u), softEdge * (0.18 + folds * 0.065) * (1.0 - smoothstep(0.75,1.0,r.uv.y)));
    }
    return float4(immerseInWater(float3(0.72,0.85,0.91),r.world,u), (1.0 - abs(r.uv.x * 2.0 - 1.0)) * 0.21 * (1.0 - r.uv.y * 0.7));
}
