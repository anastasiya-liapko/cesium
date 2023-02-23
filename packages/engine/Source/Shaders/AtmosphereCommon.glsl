uniform vec3 u_radiiAndDynamicAtmosphereColor;

uniform float u_atmosphereLightIntensity;
uniform float u_atmosphereRayleighScaleHeight;
uniform float u_atmosphereMieScaleHeight;
uniform float u_atmosphereMieAnisotropy;
uniform vec3 u_atmosphereRayleighCoefficient;
uniform vec3 u_atmosphereMieCoefficient;

const float ATMOSPHERE_THICKNESS = 111e3; // The thickness of the atmosphere in meters.

// --- Modified: constants
const int PRIMARY_STEPS = 4; // Number of times the ray from the camera to the world position (primary ray) is sampled.
const int LIGHT_STEPS = 2; // Number of times the light is sampled from the light source's intersection with the atmosphere to a sample position on the primary ray.

/**
 * This function computes the colors contributed by Rayliegh and Mie scattering on a given ray, as well as
 * the transmittance value for the ray.
 *
 * @param {czm_ray} primaryRay The ray from the camera to the position.
 * @param {float} primaryRayLength The length of the primary ray.
 * @param {vec3} lightDirection The direction of the light to calculate the scattering from.
 * @param {vec3} rayleighColor The variable the Rayleigh scattering will be written to.
 * @param {vec3} mieColor The variable the Mie scattering will be written to.
 * @param {float} opacity The variable the transmittance will be written to.
 * @glslFunction
 */
void computeScattering(
    czm_ray primaryRay,
    float primaryRayLength,
    vec3 lightDirection,
    float atmosphereInnerRadius,
    out vec3 rayleighColor,
    out vec3 mieColor,
    out float opacity
) {

    // Initialize the default scattering amounts to 0.
    rayleighColor = vec3(0.0);
    mieColor = vec3(0.0);
    opacity = 0.0;

    float atmosphereOuterRadius = atmosphereInnerRadius + ATMOSPHERE_THICKNESS;

    vec3 origin = vec3(0.0);

    // Calculate intersection from the camera to the outer ring of the atmosphere.
    czm_raySegment primaryRayAtmosphereIntersect = czm_raySphereIntersectionInterval(primaryRay, origin, atmosphereOuterRadius);

    // Return empty colors if no intersection with the atmosphere geometry.
    if (primaryRayAtmosphereIntersect == czm_emptyRaySegment) {
        return;
    }

    // To deal with smaller values of PRIMARY_STEPS (e.g. 4)
    // we implement a split strategy: sky or horizon.
    //
    // For performance reasons, instead of a if/else branch
    // a soft choice is implemented through a weight 0.0 <= w_stop_gt_lprl <= 1.0
    float lprl = length(primaryRayLength);
    float x = 1e-7 * primaryRayAtmosphereIntersect.stop / lprl;
    // w_stop_gt_lprl: similar to (1+tanh)/2
    // Value close to 0.0: close to the horizon
    // Value close to 1.0: above in the sky
    float w_stop_gt_lprl = max(0.0,min(1.0,(1.0 + x * ( 27.0 + x * x ) / ( 27.0 + 9.0 * x * x ))/2.0));

    // The ray should start from the first intersection with the outer atmopshere, or from the camera position, if it is inside the atmosphere.
    primaryRayAtmosphereIntersect.start = max(primaryRayAtmosphereIntersect.start, 0.0);
    // The ray should end at the exit from the atmosphere or at the distance to the vertex, whichever is smaller.
    primaryRayAtmosphereIntersect.stop = min(primaryRayAtmosphereIntersect.stop, lprl);

    // Sky vs horizon: constant step in one case, increasing step in the other case
    float rayStepLengthIncrease = (1.0 - w_stop_gt_lprl)*(primaryRayAtmosphereIntersect.stop - primaryRayAtmosphereIntersect.start) / (float(PRIMARY_STEPS*(PRIMARY_STEPS+1))/2.0);
    float rayStepLength         = w_stop_gt_lprl * (primaryRayAtmosphereIntersect.stop - primaryRayAtmosphereIntersect.start) / max(7.0,float(PRIMARY_STEPS));


    // Setup for sampling positions along the ray - starting from the intersection with the outer ring of the atmosphere.
    float rayStepLength = (primaryRayAtmosphereIntersect.stop - primaryRayAtmosphereIntersect.start) / float(PRIMARY_STEPS);
    float rayPositionLength = primaryRayAtmosphereIntersect.start;

    vec3 rayleighAccumulation = vec3(0.0);
    vec3 mieAccumulation = vec3(0.0);
    vec2 opticalDepth = vec2(0.0);
    vec2 heightScale = vec2(u_atmosphereRayleighScaleHeight, u_atmosphereMieScaleHeight);

    // Sample positions on the primary ray.

    // Possible small optimization
    vec3 samplePosition = primaryRay.origin + primaryRay.direction * (rayPositionLength);
    vec3 primaryPositionDelta = primaryRay.direction * rayStepLength;

    for (int i = 0; i < PRIMARY_STEPS; i++) {
        // Calculate sample position along viewpoint ray.
      samplePosition += primaryPositionDelta; // Possible small optimization
        
        // Calculate height of sample position above ellipsoid.
        float sampleHeight = length(samplePosition) - atmosphereInnerRadius;

        // Calculate and accumulate density of particles at the sample position.
        vec2 sampleDensity = exp(-sampleHeight / heightScale) * rayStepLength;
        opticalDepth += sampleDensity;

        // Generate ray from the sample position segment to the light source, up to the outer ring of the atmosphere.
        czm_ray lightRay = czm_ray(samplePosition, lightDirection);
        czm_raySegment lightRayAtmosphereIntersect = czm_raySphereIntersectionInterval(lightRay, origin, atmosphereOuterRadius);
        
        float lightStepLength = lightRayAtmosphereIntersect.stop / float(LIGHT_STEPS);
        float lightPositionLength = 0.0;

        vec2 lightOpticalDepth = vec2(0.0);

        // Sample positions along the light ray, to accumulate incidence of light on the latest sample segment.

        // Possible small optimization
        vec3 lightPosition = samplePosition + lightDirection * (lightStepLength * 0.5);
        vec3 lightPositionDelta = lightDirection * lightStepLength;
        for (int j = 0; j < LIGHT_STEPS; j++) {

            // Calculate sample position along light ray.
          lightPosition += lightPositionDelta; // Possible small optimization

            // Calculate height of the light sample position above ellipsoid.
            float lightHeight = length(lightPosition) - atmosphereInnerRadius;

            // Calculate density of photons at the light sample position.
            lightOpticalDepth += exp(-lightHeight / heightScale) * lightStepLength;

            // Increment distance on light ray.
            lightPositionLength += lightStepLength;
        }

        // Compute attenuation via the primary ray and the light ray.
        vec3 attenuation = exp(-((u_atmosphereMieCoefficient * (opticalDepth.y + lightOpticalDepth.y)) + (u_atmosphereRayleighCoefficient * (opticalDepth.x + lightOpticalDepth.x))));

        // Accumulate the scattering.
        rayleighAccumulation += sampleDensity.x * attenuation;
        mieAccumulation += sampleDensity.y * attenuation;

        // Increment distance on primary ray.
        
        // --- Modified: increasing step length
        rayPositionLength += (rayStepLength+=rayStepLengthIncrease);
    }

    // Compute the scattering amount.
    rayleighColor = u_atmosphereRayleighCoefficient * rayleighAccumulation;
    mieColor = u_atmosphereMieCoefficient * mieAccumulation;

    // Compute the transmittance i.e. how much light is passing through the atmosphere.
    opacity = length(exp(-((u_atmosphereMieCoefficient * opticalDepth.y) + (u_atmosphereRayleighCoefficient * opticalDepth.x))));
}

vec4 computeAtmosphereColor(
    vec3 positionWC,
    vec3 lightDirection,
    vec3 rayleighColor,
    vec3 mieColor,
    float opacity
) {
    // Setup the primary ray: from the camera position to the vertex position.
    vec3 cameraToPositionWC = positionWC - czm_viewerPositionWC;
    vec3 cameraToPositionWCDirection = normalize(cameraToPositionWC);

    float cosAngle = dot(cameraToPositionWCDirection, lightDirection);
    float cosAngleSq = cosAngle * cosAngle;

    float G = u_atmosphereMieAnisotropy;
    float GSq = G * G;

    // The Rayleigh phase function.
    float rayleighPhase = 3.0 / (50.2654824574) * (1.0 + cosAngleSq);
    // The Mie phase function.
    float miePhase = 3.0 / (25.1327412287) * ((1.0 - GSq) * (cosAngleSq + 1.0)) / (pow(1.0 + GSq - 2.0 * cosAngle * G, 1.5) * (2.0 + GSq));

    // The final color is generated by combining the effects of the Rayleigh and Mie scattering.
    vec3 rayleigh = rayleighPhase * rayleighColor;
    vec3 mie = miePhase * mieColor;

    vec3 color = (rayleigh + mie) * u_atmosphereLightIntensity;

    return vec4(color, opacity);
}
