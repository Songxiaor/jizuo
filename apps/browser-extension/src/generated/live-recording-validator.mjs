/* eslint-disable */
// Generated from live-recording-v1.schema.json. Do not edit by hand.
import * as __ajvFormats from "ajv-formats/dist/formats.js";
"use strict";
export const validate = validate20;
export default validate20;
const schema31 = {"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://syc.local/linkdigest/live-recording-v1.schema.json","title":"LinkDigest Live Recording V1","description":"Keyboard-free handoff for live-stream recording. Stream URLs are short-lived signed addresses: they stay in process memory, are never persisted, logged, exported or committed as fixtures. The App records in the background; the browser tab may be closed.","type":"object","required":["kind","version","requestId","createdAt","platform","pageURL","quality","variants"],"additionalProperties":true,"properties":{"kind":{"const":"liveRecording"},"version":{"const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"createdAt":{"type":"string","format":"date-time"},"platform":{"type":"string","enum":["douyin","xiaohongshu"]},"pageURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https://"},"roomID":{"type":"string","pattern":"^[A-Za-z0-9_-]{1,64}$"},"anchorName":{"type":["string","null"],"maxLength":80},"anchorID":{"type":["string","null"],"maxLength":256},"anchorAvatarURL":{"type":["string","null"],"format":"uri","maxLength":2048,"pattern":"^https://"},"anchorProfileURL":{"type":["string","null"],"format":"uri","maxLength":2048,"pattern":"^https://"},"title":{"type":["string","null"],"maxLength":200},"quality":{"type":"string","enum":["origin","hd","sd","ld"]},"variants":{"type":"array","minItems":1,"maxItems":8,"items":{"$ref":"#/$defs/Variant"}},"requestHeaders":{"type":"object","additionalProperties":true,"properties":{"referer":{"type":"string","maxLength":2048},"userAgent":{"type":"string","maxLength":512}}}},"$defs":{"Variant":{"type":"object","required":["quality","container","url"],"additionalProperties":true,"properties":{"quality":{"type":"string","enum":["origin","hd","sd","ld"]},"container":{"type":"string","enum":["flv","hls"]},"url":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"resolution":{"type":["string","null"],"maxLength":32},"label":{"type":["string","null"],"maxLength":32}}}},"x-semantic-invariants":["douyin origin quality must be recorded from an HLS variant (its FLV original is a private H.265 packaging); xiaohongshu origin is H.264 FLV and may use FLV","variant URLs are process-memory-only and excluded from persistence, logs, exports, errors and persistent fingerprints","the App records only streams whose pageURL host belongs to the declared platform","anchor fields describe the streamer at recording start; anchorAvatarURL and anchorProfileURL are public page metadata and may be persisted, while variant URLs never are"]};
const schema32 = {"type":"object","required":["quality","container","url"],"additionalProperties":true,"properties":{"quality":{"type":"string","enum":["origin","hd","sd","ld"]},"container":{"type":"string","enum":["flv","hls"]},"url":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"resolution":{"type":["string","null"],"maxLength":32},"label":{"type":["string","null"],"maxLength":32}}};
const func1 = (value) => [...value].length;
const formats0 = __ajvFormats.fullFormats["date-time"];
const formats2 = __ajvFormats.fullFormats.uri;
const pattern4 = new RegExp("^https://", "u");
const pattern5 = new RegExp("^[A-Za-z0-9_-]{1,64}$", "u");
const pattern8 = new RegExp("^https?://", "u");

function validate20(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
/*# sourceURL="https://syc.local/linkdigest/live-recording-v1.schema.json" */;
let vErrors = null;
let errors = 0;
const evaluated0 = validate20.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
if(data && typeof data == "object" && !Array.isArray(data)){
if(data.kind === undefined){
const err0 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
if(data.version === undefined){
const err1 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "version"},message:"must have required property '"+"version"+"'"};
if(vErrors === null){
vErrors = [err1];
}
else {
vErrors.push(err1);
}
errors++;
}
if(data.requestId === undefined){
const err2 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "requestId"},message:"must have required property '"+"requestId"+"'"};
if(vErrors === null){
vErrors = [err2];
}
else {
vErrors.push(err2);
}
errors++;
}
if(data.createdAt === undefined){
const err3 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "createdAt"},message:"must have required property '"+"createdAt"+"'"};
if(vErrors === null){
vErrors = [err3];
}
else {
vErrors.push(err3);
}
errors++;
}
if(data.platform === undefined){
const err4 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "platform"},message:"must have required property '"+"platform"+"'"};
if(vErrors === null){
vErrors = [err4];
}
else {
vErrors.push(err4);
}
errors++;
}
if(data.pageURL === undefined){
const err5 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "pageURL"},message:"must have required property '"+"pageURL"+"'"};
if(vErrors === null){
vErrors = [err5];
}
else {
vErrors.push(err5);
}
errors++;
}
if(data.quality === undefined){
const err6 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "quality"},message:"must have required property '"+"quality"+"'"};
if(vErrors === null){
vErrors = [err6];
}
else {
vErrors.push(err6);
}
errors++;
}
if(data.variants === undefined){
const err7 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "variants"},message:"must have required property '"+"variants"+"'"};
if(vErrors === null){
vErrors = [err7];
}
else {
vErrors.push(err7);
}
errors++;
}
if(data.kind !== undefined){
if("liveRecording" !== data.kind){
const err8 = {instancePath:instancePath+"/kind",schemaPath:"#/properties/kind/const",keyword:"const",params:{allowedValue: "liveRecording"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err8];
}
else {
vErrors.push(err8);
}
errors++;
}
}
if(data.version !== undefined){
if(1 !== data.version){
const err9 = {instancePath:instancePath+"/version",schemaPath:"#/properties/version/const",keyword:"const",params:{allowedValue: 1},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err9];
}
else {
vErrors.push(err9);
}
errors++;
}
}
if(data.requestId !== undefined){
let data2 = data.requestId;
if(typeof data2 === "string"){
if(func1(data2) > 128){
const err10 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err10];
}
else {
vErrors.push(err10);
}
errors++;
}
if(func1(data2) < 1){
const err11 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err11];
}
else {
vErrors.push(err11);
}
errors++;
}
}
else {
const err12 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err12];
}
else {
vErrors.push(err12);
}
errors++;
}
}
if(data.createdAt !== undefined){
let data3 = data.createdAt;
if(typeof data3 === "string"){
if(!(formats0.validate(data3))){
const err13 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
if(vErrors === null){
vErrors = [err13];
}
else {
vErrors.push(err13);
}
errors++;
}
}
else {
const err14 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err14];
}
else {
vErrors.push(err14);
}
errors++;
}
}
if(data.platform !== undefined){
let data4 = data.platform;
if(typeof data4 !== "string"){
const err15 = {instancePath:instancePath+"/platform",schemaPath:"#/properties/platform/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err15];
}
else {
vErrors.push(err15);
}
errors++;
}
if(!((data4 === "douyin") || (data4 === "xiaohongshu"))){
const err16 = {instancePath:instancePath+"/platform",schemaPath:"#/properties/platform/enum",keyword:"enum",params:{allowedValues: schema31.properties.platform.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err16];
}
else {
vErrors.push(err16);
}
errors++;
}
}
if(data.pageURL !== undefined){
let data5 = data.pageURL;
if(typeof data5 === "string"){
if(func1(data5) > 8192){
const err17 = {instancePath:instancePath+"/pageURL",schemaPath:"#/properties/pageURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err17];
}
else {
vErrors.push(err17);
}
errors++;
}
if(!pattern4.test(data5)){
const err18 = {instancePath:instancePath+"/pageURL",schemaPath:"#/properties/pageURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err18];
}
else {
vErrors.push(err18);
}
errors++;
}
if(!(formats2(data5))){
const err19 = {instancePath:instancePath+"/pageURL",schemaPath:"#/properties/pageURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err19];
}
else {
vErrors.push(err19);
}
errors++;
}
}
else {
const err20 = {instancePath:instancePath+"/pageURL",schemaPath:"#/properties/pageURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err20];
}
else {
vErrors.push(err20);
}
errors++;
}
}
if(data.roomID !== undefined){
let data6 = data.roomID;
if(typeof data6 === "string"){
if(!pattern5.test(data6)){
const err21 = {instancePath:instancePath+"/roomID",schemaPath:"#/properties/roomID/pattern",keyword:"pattern",params:{pattern: "^[A-Za-z0-9_-]{1,64}$"},message:"must match pattern \""+"^[A-Za-z0-9_-]{1,64}$"+"\""};
if(vErrors === null){
vErrors = [err21];
}
else {
vErrors.push(err21);
}
errors++;
}
}
else {
const err22 = {instancePath:instancePath+"/roomID",schemaPath:"#/properties/roomID/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err22];
}
else {
vErrors.push(err22);
}
errors++;
}
}
if(data.anchorName !== undefined){
let data7 = data.anchorName;
if((typeof data7 !== "string") && (data7 !== null)){
const err23 = {instancePath:instancePath+"/anchorName",schemaPath:"#/properties/anchorName/type",keyword:"type",params:{type: schema31.properties.anchorName.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err23];
}
else {
vErrors.push(err23);
}
errors++;
}
if(typeof data7 === "string"){
if(func1(data7) > 80){
const err24 = {instancePath:instancePath+"/anchorName",schemaPath:"#/properties/anchorName/maxLength",keyword:"maxLength",params:{limit: 80},message:"must NOT have more than 80 characters"};
if(vErrors === null){
vErrors = [err24];
}
else {
vErrors.push(err24);
}
errors++;
}
}
}
if(data.anchorID !== undefined){
let data8 = data.anchorID;
if((typeof data8 !== "string") && (data8 !== null)){
const err25 = {instancePath:instancePath+"/anchorID",schemaPath:"#/properties/anchorID/type",keyword:"type",params:{type: schema31.properties.anchorID.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err25];
}
else {
vErrors.push(err25);
}
errors++;
}
if(typeof data8 === "string"){
if(func1(data8) > 256){
const err26 = {instancePath:instancePath+"/anchorID",schemaPath:"#/properties/anchorID/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err26];
}
else {
vErrors.push(err26);
}
errors++;
}
}
}
if(data.anchorAvatarURL !== undefined){
let data9 = data.anchorAvatarURL;
if((typeof data9 !== "string") && (data9 !== null)){
const err27 = {instancePath:instancePath+"/anchorAvatarURL",schemaPath:"#/properties/anchorAvatarURL/type",keyword:"type",params:{type: schema31.properties.anchorAvatarURL.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err27];
}
else {
vErrors.push(err27);
}
errors++;
}
if(typeof data9 === "string"){
if(func1(data9) > 2048){
const err28 = {instancePath:instancePath+"/anchorAvatarURL",schemaPath:"#/properties/anchorAvatarURL/maxLength",keyword:"maxLength",params:{limit: 2048},message:"must NOT have more than 2048 characters"};
if(vErrors === null){
vErrors = [err28];
}
else {
vErrors.push(err28);
}
errors++;
}
if(!pattern4.test(data9)){
const err29 = {instancePath:instancePath+"/anchorAvatarURL",schemaPath:"#/properties/anchorAvatarURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err29];
}
else {
vErrors.push(err29);
}
errors++;
}
if(!(formats2(data9))){
const err30 = {instancePath:instancePath+"/anchorAvatarURL",schemaPath:"#/properties/anchorAvatarURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err30];
}
else {
vErrors.push(err30);
}
errors++;
}
}
}
if(data.anchorProfileURL !== undefined){
let data10 = data.anchorProfileURL;
if((typeof data10 !== "string") && (data10 !== null)){
const err31 = {instancePath:instancePath+"/anchorProfileURL",schemaPath:"#/properties/anchorProfileURL/type",keyword:"type",params:{type: schema31.properties.anchorProfileURL.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err31];
}
else {
vErrors.push(err31);
}
errors++;
}
if(typeof data10 === "string"){
if(func1(data10) > 2048){
const err32 = {instancePath:instancePath+"/anchorProfileURL",schemaPath:"#/properties/anchorProfileURL/maxLength",keyword:"maxLength",params:{limit: 2048},message:"must NOT have more than 2048 characters"};
if(vErrors === null){
vErrors = [err32];
}
else {
vErrors.push(err32);
}
errors++;
}
if(!pattern4.test(data10)){
const err33 = {instancePath:instancePath+"/anchorProfileURL",schemaPath:"#/properties/anchorProfileURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err33];
}
else {
vErrors.push(err33);
}
errors++;
}
if(!(formats2(data10))){
const err34 = {instancePath:instancePath+"/anchorProfileURL",schemaPath:"#/properties/anchorProfileURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err34];
}
else {
vErrors.push(err34);
}
errors++;
}
}
}
if(data.title !== undefined){
let data11 = data.title;
if((typeof data11 !== "string") && (data11 !== null)){
const err35 = {instancePath:instancePath+"/title",schemaPath:"#/properties/title/type",keyword:"type",params:{type: schema31.properties.title.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err35];
}
else {
vErrors.push(err35);
}
errors++;
}
if(typeof data11 === "string"){
if(func1(data11) > 200){
const err36 = {instancePath:instancePath+"/title",schemaPath:"#/properties/title/maxLength",keyword:"maxLength",params:{limit: 200},message:"must NOT have more than 200 characters"};
if(vErrors === null){
vErrors = [err36];
}
else {
vErrors.push(err36);
}
errors++;
}
}
}
if(data.quality !== undefined){
let data12 = data.quality;
if(typeof data12 !== "string"){
const err37 = {instancePath:instancePath+"/quality",schemaPath:"#/properties/quality/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err37];
}
else {
vErrors.push(err37);
}
errors++;
}
if(!((((data12 === "origin") || (data12 === "hd")) || (data12 === "sd")) || (data12 === "ld"))){
const err38 = {instancePath:instancePath+"/quality",schemaPath:"#/properties/quality/enum",keyword:"enum",params:{allowedValues: schema31.properties.quality.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err38];
}
else {
vErrors.push(err38);
}
errors++;
}
}
if(data.variants !== undefined){
let data13 = data.variants;
if(Array.isArray(data13)){
if(data13.length > 8){
const err39 = {instancePath:instancePath+"/variants",schemaPath:"#/properties/variants/maxItems",keyword:"maxItems",params:{limit: 8},message:"must NOT have more than 8 items"};
if(vErrors === null){
vErrors = [err39];
}
else {
vErrors.push(err39);
}
errors++;
}
if(data13.length < 1){
const err40 = {instancePath:instancePath+"/variants",schemaPath:"#/properties/variants/minItems",keyword:"minItems",params:{limit: 1},message:"must NOT have fewer than 1 items"};
if(vErrors === null){
vErrors = [err40];
}
else {
vErrors.push(err40);
}
errors++;
}
const len0 = data13.length;
for(let i0=0; i0<len0; i0++){
let data14 = data13[i0];
if(data14 && typeof data14 == "object" && !Array.isArray(data14)){
if(data14.quality === undefined){
const err41 = {instancePath:instancePath+"/variants/" + i0,schemaPath:"#/$defs/Variant/required",keyword:"required",params:{missingProperty: "quality"},message:"must have required property '"+"quality"+"'"};
if(vErrors === null){
vErrors = [err41];
}
else {
vErrors.push(err41);
}
errors++;
}
if(data14.container === undefined){
const err42 = {instancePath:instancePath+"/variants/" + i0,schemaPath:"#/$defs/Variant/required",keyword:"required",params:{missingProperty: "container"},message:"must have required property '"+"container"+"'"};
if(vErrors === null){
vErrors = [err42];
}
else {
vErrors.push(err42);
}
errors++;
}
if(data14.url === undefined){
const err43 = {instancePath:instancePath+"/variants/" + i0,schemaPath:"#/$defs/Variant/required",keyword:"required",params:{missingProperty: "url"},message:"must have required property '"+"url"+"'"};
if(vErrors === null){
vErrors = [err43];
}
else {
vErrors.push(err43);
}
errors++;
}
if(data14.quality !== undefined){
let data15 = data14.quality;
if(typeof data15 !== "string"){
const err44 = {instancePath:instancePath+"/variants/" + i0+"/quality",schemaPath:"#/$defs/Variant/properties/quality/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err44];
}
else {
vErrors.push(err44);
}
errors++;
}
if(!((((data15 === "origin") || (data15 === "hd")) || (data15 === "sd")) || (data15 === "ld"))){
const err45 = {instancePath:instancePath+"/variants/" + i0+"/quality",schemaPath:"#/$defs/Variant/properties/quality/enum",keyword:"enum",params:{allowedValues: schema32.properties.quality.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err45];
}
else {
vErrors.push(err45);
}
errors++;
}
}
if(data14.container !== undefined){
let data16 = data14.container;
if(typeof data16 !== "string"){
const err46 = {instancePath:instancePath+"/variants/" + i0+"/container",schemaPath:"#/$defs/Variant/properties/container/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err46];
}
else {
vErrors.push(err46);
}
errors++;
}
if(!((data16 === "flv") || (data16 === "hls"))){
const err47 = {instancePath:instancePath+"/variants/" + i0+"/container",schemaPath:"#/$defs/Variant/properties/container/enum",keyword:"enum",params:{allowedValues: schema32.properties.container.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err47];
}
else {
vErrors.push(err47);
}
errors++;
}
}
if(data14.url !== undefined){
let data17 = data14.url;
if(typeof data17 === "string"){
if(func1(data17) > 8192){
const err48 = {instancePath:instancePath+"/variants/" + i0+"/url",schemaPath:"#/$defs/Variant/properties/url/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err48];
}
else {
vErrors.push(err48);
}
errors++;
}
if(!pattern8.test(data17)){
const err49 = {instancePath:instancePath+"/variants/" + i0+"/url",schemaPath:"#/$defs/Variant/properties/url/pattern",keyword:"pattern",params:{pattern: "^https?://"},message:"must match pattern \""+"^https?://"+"\""};
if(vErrors === null){
vErrors = [err49];
}
else {
vErrors.push(err49);
}
errors++;
}
if(!(formats2(data17))){
const err50 = {instancePath:instancePath+"/variants/" + i0+"/url",schemaPath:"#/$defs/Variant/properties/url/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err50];
}
else {
vErrors.push(err50);
}
errors++;
}
}
else {
const err51 = {instancePath:instancePath+"/variants/" + i0+"/url",schemaPath:"#/$defs/Variant/properties/url/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err51];
}
else {
vErrors.push(err51);
}
errors++;
}
}
if(data14.resolution !== undefined){
let data18 = data14.resolution;
if((typeof data18 !== "string") && (data18 !== null)){
const err52 = {instancePath:instancePath+"/variants/" + i0+"/resolution",schemaPath:"#/$defs/Variant/properties/resolution/type",keyword:"type",params:{type: schema32.properties.resolution.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err52];
}
else {
vErrors.push(err52);
}
errors++;
}
if(typeof data18 === "string"){
if(func1(data18) > 32){
const err53 = {instancePath:instancePath+"/variants/" + i0+"/resolution",schemaPath:"#/$defs/Variant/properties/resolution/maxLength",keyword:"maxLength",params:{limit: 32},message:"must NOT have more than 32 characters"};
if(vErrors === null){
vErrors = [err53];
}
else {
vErrors.push(err53);
}
errors++;
}
}
}
if(data14.label !== undefined){
let data19 = data14.label;
if((typeof data19 !== "string") && (data19 !== null)){
const err54 = {instancePath:instancePath+"/variants/" + i0+"/label",schemaPath:"#/$defs/Variant/properties/label/type",keyword:"type",params:{type: schema32.properties.label.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err54];
}
else {
vErrors.push(err54);
}
errors++;
}
if(typeof data19 === "string"){
if(func1(data19) > 32){
const err55 = {instancePath:instancePath+"/variants/" + i0+"/label",schemaPath:"#/$defs/Variant/properties/label/maxLength",keyword:"maxLength",params:{limit: 32},message:"must NOT have more than 32 characters"};
if(vErrors === null){
vErrors = [err55];
}
else {
vErrors.push(err55);
}
errors++;
}
}
}
}
else {
const err56 = {instancePath:instancePath+"/variants/" + i0,schemaPath:"#/$defs/Variant/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err56];
}
else {
vErrors.push(err56);
}
errors++;
}
}
}
else {
const err57 = {instancePath:instancePath+"/variants",schemaPath:"#/properties/variants/type",keyword:"type",params:{type: "array"},message:"must be array"};
if(vErrors === null){
vErrors = [err57];
}
else {
vErrors.push(err57);
}
errors++;
}
}
if(data.requestHeaders !== undefined){
let data20 = data.requestHeaders;
if(data20 && typeof data20 == "object" && !Array.isArray(data20)){
if(data20.referer !== undefined){
let data21 = data20.referer;
if(typeof data21 === "string"){
if(func1(data21) > 2048){
const err58 = {instancePath:instancePath+"/requestHeaders/referer",schemaPath:"#/properties/requestHeaders/properties/referer/maxLength",keyword:"maxLength",params:{limit: 2048},message:"must NOT have more than 2048 characters"};
if(vErrors === null){
vErrors = [err58];
}
else {
vErrors.push(err58);
}
errors++;
}
}
else {
const err59 = {instancePath:instancePath+"/requestHeaders/referer",schemaPath:"#/properties/requestHeaders/properties/referer/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err59];
}
else {
vErrors.push(err59);
}
errors++;
}
}
if(data20.userAgent !== undefined){
let data22 = data20.userAgent;
if(typeof data22 === "string"){
if(func1(data22) > 512){
const err60 = {instancePath:instancePath+"/requestHeaders/userAgent",schemaPath:"#/properties/requestHeaders/properties/userAgent/maxLength",keyword:"maxLength",params:{limit: 512},message:"must NOT have more than 512 characters"};
if(vErrors === null){
vErrors = [err60];
}
else {
vErrors.push(err60);
}
errors++;
}
}
else {
const err61 = {instancePath:instancePath+"/requestHeaders/userAgent",schemaPath:"#/properties/requestHeaders/properties/userAgent/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err61];
}
else {
vErrors.push(err61);
}
errors++;
}
}
}
else {
const err62 = {instancePath:instancePath+"/requestHeaders",schemaPath:"#/properties/requestHeaders/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err62];
}
else {
vErrors.push(err62);
}
errors++;
}
}
}
else {
const err63 = {instancePath,schemaPath:"#/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err63];
}
else {
vErrors.push(err63);
}
errors++;
}
validate20.errors = vErrors;
return errors === 0;
}
validate20.evaluated = {"props":true,"dynamicProps":false,"dynamicItems":false};
