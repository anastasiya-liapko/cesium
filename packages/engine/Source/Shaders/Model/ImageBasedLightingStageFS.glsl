vec3 proceduralIBL(
    vec3 positionEC,
    vec3 normalEC,
    vec3 lightDirectionEC,
    vec3 lightColorHdr,
    czm_pbrParameters pbrParameters
) {
    vec3 v = -normalize(positionEC);
    vec3 positionWC = vec3(czm_inverseView * vec4(positionEC, 1.0));
    vec3 vWC = -normalize(positionWC);
    vec3 l = normalize(lightDirectionEC);
    vec3 n = normalEC;
    vec3 r = normalize(czm_inverseViewRotation * normalize(reflect(v, n)));

    float NdotL = clamp(dot(n, l), 0.001, 1.0);
    float NdotV = abs(dot(n, v)) + 0.001;

    // Figure out if the reflection vector hits the ellipsoid
    float vertexRadius = length(positionWC);
    float horizonDotNadir = 1.0 - min(1.0, czm_ellipsoidRadii.x / vertexRadius);
    float reflectionDotNadir = dot(r, normalize(positionWC));
    // Flipping the X vector is a cheap way to get the inverse of czm_temeToPseudoFixed, since that's a rotation about Z.
    r.x = -r.x;
    r = -normalize(czm_temeToPseudoFixed * r);
    r.x = -r.x;

    vec3 diffuseColor = pbrParameters.diffuseColor;
    float roughness = pbrParameters.roughness;
    vec3 f0 = pbrParameters.f0;

    float inverseRoughness = 1.04 - roughness;
    inverseRoughness *= inverseRoughness;
    vec3 sceneSkyBox = czm_textureCube(czm_environmentMap, r).rgb * inverseRoughness;

    float atmosphereHeight = 0.05;
    float blendRegionSize = 0.1 * ((1.0 - inverseRoughness) * 8.0 + 1.1 - horizonDotNadir);
    float blendRegionOffset = roughness * -1.0;
    float farAboveHorizon = clamp(horizonDotNadir - blendRegionSize * 0.5 + blendRegionOffset, 1.0e-10 - blendRegionSize, 0.99999);
    float aroundHorizon = clamp(horizonDotNadir + blendRegionSize * 0.5, 1.0e-10 - blendRegionSize, 0.99999);
    float farBelowHorizon = clamp(horizonDotNadir + blendRegionSize * 1.5, 1.0e-10 - blendRegionSize, 0.99999);
    float smoothstepHeight = smoothstep(0.0, atmosphereHeight, horizonDotNadir);
    vec3 belowHorizonColor = mix(vec3(0.1, 0.15, 0.25), vec3(0.4, 0.7, 0.9), smoothstepHeight);
    vec3 nadirColor = belowHorizonColor * 0.5;
    vec3 aboveHorizonColor = mix(vec3(0.9, 1.0, 1.2), belowHorizonColor, roughness * 0.5);
    vec3 blueSkyColor = mix(vec3(0.18, 0.26, 0.48), aboveHorizonColor, reflectionDotNadir * inverseRoughness * 0.5 + 0.75);
    vec3 zenithColor = mix(blueSkyColor, sceneSkyBox, smoothstepHeight);
    vec3 blueSkyDiffuseColor = vec3(0.7, 0.85, 0.9); 
    float diffuseIrradianceFromEarth = (1.0 - horizonDotNadir) * (reflectionDotNadir * 0.25 + 0.75) * smoothstepHeight;  
    float diffuseIrradianceFromSky = (1.0 - smoothstepHeight) * (1.0 - (reflectionDotNadir * 0.25 + 0.25));
    vec3 diffuseIrradiance = blueSkyDiffuseColor * clamp(diffuseIrradianceFromEarth + diffuseIrradianceFromSky, 0.0, 1.0);
    float notDistantRough = (1.0 - horizonDotNadir * roughness * 0.8);
    vec3 specularIrradiance = mix(zenithColor, aboveHorizonColor, smoothstep(farAboveHorizon, aroundHorizon, reflectionDotNadir) * notDistantRough);
    specularIrradiance = mix(specularIrradiance, belowHorizonColor, smoothstep(aroundHorizon, farBelowHorizon, reflectionDotNadir) * inverseRoughness);
    specularIrradiance = mix(specularIrradiance, nadirColor, smoothstep(farBelowHorizon, 1.0, reflectionDotNadir) * inverseRoughness);

    #ifdef USE_SUN_LUMINANCE
    // See the "CIE Clear Sky Model" referenced on page 40 of https://3dvar.com/Green2003Spherical.pdf
    // Angle between sun and zenith.
    float LdotZenith = clamp(dot(normalize(czm_inverseViewRotation * l), vWC), 0.001, 1.0);
    float S = acos(LdotZenith);
    // Angle between zenith and current pixel
    float NdotZenith = clamp(dot(normalize(czm_inverseViewRotation * n), vWC), 0.001, 1.0);
    // Angle between sun and current pixel
    float gamma = acos(NdotL);
    float numerator = ((0.91 + 10.0 * exp(-3.0 * gamma) + 0.45 * NdotL * NdotL) * (1.0 - exp(-0.32 / NdotZenith)));
    float denominator = (0.91 + 10.0 * exp(-3.0 * S) + 0.45 * LdotZenith * LdotZenith) * (1.0 - exp(-0.32));
    float luminance = model_luminanceAtZenith * (numerator / denominator);
    #endif

    vec2 brdfLut = texture(czm_brdfLut, vec2(NdotV, roughness)).rg;
    vec3 specularColor = czm_srgbToLinear(f0 * brdfLut.x + brdfLut.y);
    vec3 specularContribution = specularIrradiance * specularColor * model_iblFactor.y;
    #ifdef USE_SPECULAR
        specularContribution *= pbrParameters.specularWeight;
    #endif
    vec3 diffuseContribution = diffuseIrradiance * diffuseColor * model_iblFactor.x;
    vec3 iblColor = specularContribution + diffuseContribution;
    float maximumComponent = max(max(lightColorHdr.x, lightColorHdr.y), lightColorHdr.z);
    vec3 lightColor = lightColorHdr / max(maximumComponent, 1.0);
    iblColor *= lightColor;

    #ifdef USE_SUN_LUMINANCE
    iblColor *= luminance;
    #endif

    return iblColor;
}

#ifdef DIFFUSE_IBL
vec3 computeDiffuseIBL(czm_pbrParameters pbrParameters, vec3 cubeDir)
{
    #ifdef CUSTOM_SPHERICAL_HARMONICS
        vec3 diffuseIrradiance = czm_sphericalHarmonics(cubeDir, model_sphericalHarmonicCoefficients); 
    #else
        vec3 diffuseIrradiance = czm_sphericalHarmonics(cubeDir, czm_sphericalHarmonicCoefficients); 
    #endif 
    return diffuseIrradiance * pbrParameters.diffuseColor;
}
#endif

#ifdef SPECULAR_IBL
vec3 sampleSpecularEnvironment(vec3 cubeDir, float roughness)
{
    #ifdef CUSTOM_SPECULAR_IBL
        float maxLod = model_specularEnvironmentMapsMaximumLOD;
        float lod = roughness * maxLod;
        return czm_sampleOctahedralProjection(model_specularEnvironmentMaps, model_specularEnvironmentMapsSize, cubeDir, lod, maxLod);
    #else
        float maxLod = czm_specularEnvironmentMapsMaximumLOD;
        float lod = roughness * maxLod;
        return czm_sampleOctahedralProjection(czm_specularEnvironmentMaps, czm_specularEnvironmentMapSize, cubeDir, lod, maxLod);
    #endif
}
vec3 computeSpecularIBL(czm_pbrParameters pbrParameters, vec3 cubeDir, float NdotV, float VdotH)
{
    float roughness = pbrParameters.roughness;
    vec3 f0 = pbrParameters.f0;

    float reflectance = max(max(f0.r, f0.g), f0.b);
    vec3 f90 = vec3(clamp(reflectance * 25.0, 0.0, 1.0));
    vec3 F = fresnelSchlick2(f0, f90, VdotH);

    vec2 brdfLut = texture(czm_brdfLut, vec2(NdotV, roughness)).rg;
    vec3 specularIBL = sampleSpecularEnvironment(cubeDir, roughness);
    specularIBL *= F * brdfLut.x + brdfLut.y;

    #ifdef USE_SPECULAR
        specularIBL *= pbrParameters.specularWeight;
    #endif

    return f0 * specularIBL;
}
#endif

#if defined(DIFFUSE_IBL) || defined(SPECULAR_IBL)
vec3 textureIBL(
    vec3 positionEC,
    vec3 normalEC,
    vec3 lightDirectionEC,
    czm_pbrParameters pbrParameters
) {
    vec3 v = -normalize(positionEC);
    vec3 n = normalEC;
    vec3 l = normalize(lightDirectionEC);
    vec3 h = normalize(v + l);

    float NdotV = abs(dot(n, v)) + 0.001;
    float VdotH = clamp(dot(v, h), 0.0, 1.0);

    // Find the direction in which to sample the environment map
    const mat3 yUpToZUp = mat3(
        -1.0, 0.0, 0.0,
        0.0, 0.0, -1.0, 
        0.0, 1.0, 0.0
    );
    mat3 cubeDirTransform = yUpToZUp * model_iblReferenceFrameMatrix;
    vec3 cubeDir = normalize(cubeDirTransform * normalize(reflect(-v, n)));

    #ifdef DIFFUSE_IBL
        vec3 diffuseContribution = computeDiffuseIBL(pbrParameters, cubeDir);
    #else
        vec3 diffuseContribution = vec3(0.0); 
    #endif

    #ifdef USE_ANISOTROPY
        // Update environment map sampling direction to account for anisotropic distortion of specular reflection
        float roughness = pbrParameters.roughness;
        vec3 anisotropyDirection = pbrParameters.anisotropicB;
        float anisotropyStrength = pbrParameters.anisotropyStrength;

        vec3 anisotropicTangent = cross(anisotropyDirection, v);
        vec3 anisotropicNormal = cross(anisotropicTangent, anisotropyDirection);
        float bendFactor = 1.0 - anisotropyStrength * (1.0 - roughness);
        float bendFactorPow4 = bendFactor * bendFactor * bendFactor * bendFactor;
        vec3 bentNormal = normalize(mix(anisotropicNormal, n, bendFactorPow4));
        cubeDir = normalize(cubeDirTransform * normalize(reflect(-v, bentNormal)));
    #endif

    #ifdef SPECULAR_IBL
        vec3 specularContribution = computeSpecularIBL(pbrParameters, cubeDir, NdotV, VdotH);
    #else
        vec3 specularContribution = vec3(0.0); 
    #endif

    return diffuseContribution + specularContribution;
}
#endif

vec3 imageBasedLightingStage(
    vec3 positionEC,
    vec3 normalEC,
    vec3 lightDirectionEC,
    vec3 lightColorHdr,
    czm_pbrParameters pbrParameters
) {
    #if defined(DIFFUSE_IBL) || defined(SPECULAR_IBL)
    // Environment maps were provided, use them for IBL
    return textureIBL(
        positionEC,
        normalEC,
        lightDirectionEC,
        pbrParameters
    );
    #else
    // Use the procedural IBL if there are no environment maps
    return proceduralIBL(
        positionEC,
        normalEC,
        lightDirectionEC,
        lightColorHdr,
        pbrParameters
    );
    #endif
}