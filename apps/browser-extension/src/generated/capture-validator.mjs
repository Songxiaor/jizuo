/* eslint-disable */
// Generated from capture-envelope-v1.schema.json + capture-envelope-v2.schema.json. Do not edit by hand.
import * as __ajvFormats from "ajv-formats/dist/formats.js";
"use strict";
export const validate = validate20;
export default validate20;
const schema31 = {"$id":"https://syc.local/linkdigest/capture-envelope-wire.schema.json","oneOf":[{"$ref":"https://syc.local/linkdigest/capture-envelope-v1.schema.json"},{"$ref":"https://syc.local/linkdigest/capture-envelope-v2.schema.json"}]};
const schema32 = {"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://syc.local/linkdigest/capture-envelope-v1.schema.json","title":"LinkDigest V0.1 Capture Contract","description":"Language-neutral Native Messaging contract. Objects accept unknown optional fields for forward compatibility; required fields and semantic invariants remain enforced by both runtimes.","type":"object","required":["version","requestId","createdAt","source","capture","evidence"],"additionalProperties":true,"properties":{"version":{"const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"createdAt":{"type":"string","format":"date-time"},"idempotencyKey":{"type":"string","minLength":1,"maxLength":256},"requestedAction":{"type":"string","enum":["save","summarize","translate"]},"source":{"type":"object","required":["kind","url","title","platform"],"additionalProperties":true,"properties":{"kind":{"const":"browser_capture"},"url":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"title":{"type":["string","null"],"maxLength":1024},"platform":{"type":"string","enum":["generic","x","youtube","wechat","xiaohongshu","douyin","bilibili","github","zhihu","medium","substack","toutiao"]}}},"capture":{"type":"object","required":["method","text","characterCount","completeness","capturedAt"],"additionalProperties":true,"properties":{"method":{"type":"string","enum":["rendered_dom","selection"]},"text":{"type":"string","minLength":1,"maxLength":2000000},"characterCount":{"type":"integer","minimum":1,"maximum":2000000},"completeness":{"type":"string","enum":["full_article","visible_only","selection_only","unknown"]},"capturedAt":{"type":"string","format":"date-time"}}},"evidence":{"type":"object","required":["sourceLabel","usedCookie"],"additionalProperties":true,"properties":{"sourceLabel":{"type":"string","minLength":1,"maxLength":128},"usedCookie":{"const":false}}},"media":{"type":"object","required":["platform","videoURL"],"additionalProperties":true,"description":"Optional media block for video-capable captures (Loop V). Omitted envelopes remain pure text. Signed playback URLs must be downloaded immediately and must not be retained for later reuse.","properties":{"platform":{"type":"string","enum":["douyin"]},"videoURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https://"},"coverURL":{"type":["string","null"],"format":"uri","maxLength":8192,"pattern":"^https://"},"durationSeconds":{"type":["number","null"],"minimum":0,"maximum":86400},"author":{"type":["string","null"],"maxLength":256}}}},"$defs":{"AppError":{"type":"object","required":["version","requestId","createdAt","category","code","retryable","action"],"additionalProperties":true,"properties":{"version":{"const":1},"requestId":{"type":"string","minLength":1,"maxLength":128},"createdAt":{"type":"string","format":"date-time"},"category":{"type":"string","enum":["protocol","permission","network","extraction","storage","unknown"]},"code":{"type":"string","pattern":"^[A-Z][A-Z0-9_]{2,63}$"},"retryable":{"type":"boolean"},"action":{"type":"string","enum":["retry","open_app","open_install_guide","open_in_browser","grant_permission","upgrade_app","none"]},"safeDetail":{"type":"string","maxLength":2000}}},"NativeResponse":{"oneOf":[{"type":"object","required":["kind","version","requestId","characterCount"],"additionalProperties":true,"properties":{"kind":{"const":"taskAccepted"},"version":{"const":1},"requestId":{"type":"string"},"characterCount":{"type":"integer"}}},{"type":"object","required":["kind","error"],"additionalProperties":true,"properties":{"kind":{"const":"error"},"error":{"$ref":"#/$defs/AppError"}}}]}},"x-semantic-invariants":["capture.characterCount equals the Unicode code point count of capture.text (Swift scalar count; TypeScript [...text].length)","capture.text and all URL/title fields are never written to ordinary logs","Native Messaging framing limit is 4 MiB bytes; text limit is 2,000,000 Unicode scalars"]};
const func1 = (value) => [...value].length;
const formats0 = __ajvFormats.fullFormats["date-time"];
const formats2 = __ajvFormats.fullFormats.uri;
const pattern4 = new RegExp("^https?://", "u");
const pattern5 = new RegExp("^https://", "u");

function validate21(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
/*# sourceURL="https://syc.local/linkdigest/capture-envelope-v1.schema.json" */;
let vErrors = null;
let errors = 0;
const evaluated0 = validate21.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
if(data && typeof data == "object" && !Array.isArray(data)){
if(data.version === undefined){
const err0 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "version"},message:"must have required property '"+"version"+"'"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
if(data.requestId === undefined){
const err1 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "requestId"},message:"must have required property '"+"requestId"+"'"};
if(vErrors === null){
vErrors = [err1];
}
else {
vErrors.push(err1);
}
errors++;
}
if(data.createdAt === undefined){
const err2 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "createdAt"},message:"must have required property '"+"createdAt"+"'"};
if(vErrors === null){
vErrors = [err2];
}
else {
vErrors.push(err2);
}
errors++;
}
if(data.source === undefined){
const err3 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "source"},message:"must have required property '"+"source"+"'"};
if(vErrors === null){
vErrors = [err3];
}
else {
vErrors.push(err3);
}
errors++;
}
if(data.capture === undefined){
const err4 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "capture"},message:"must have required property '"+"capture"+"'"};
if(vErrors === null){
vErrors = [err4];
}
else {
vErrors.push(err4);
}
errors++;
}
if(data.evidence === undefined){
const err5 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "evidence"},message:"must have required property '"+"evidence"+"'"};
if(vErrors === null){
vErrors = [err5];
}
else {
vErrors.push(err5);
}
errors++;
}
if(data.version !== undefined){
if(1 !== data.version){
const err6 = {instancePath:instancePath+"/version",schemaPath:"#/properties/version/const",keyword:"const",params:{allowedValue: 1},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err6];
}
else {
vErrors.push(err6);
}
errors++;
}
}
if(data.requestId !== undefined){
let data1 = data.requestId;
if(typeof data1 === "string"){
if(func1(data1) > 128){
const err7 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err7];
}
else {
vErrors.push(err7);
}
errors++;
}
if(func1(data1) < 1){
const err8 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err8];
}
else {
vErrors.push(err8);
}
errors++;
}
}
else {
const err9 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err9];
}
else {
vErrors.push(err9);
}
errors++;
}
}
if(data.createdAt !== undefined){
let data2 = data.createdAt;
if(typeof data2 === "string"){
if(!(formats0.validate(data2))){
const err10 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
if(vErrors === null){
vErrors = [err10];
}
else {
vErrors.push(err10);
}
errors++;
}
}
else {
const err11 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err11];
}
else {
vErrors.push(err11);
}
errors++;
}
}
if(data.idempotencyKey !== undefined){
let data3 = data.idempotencyKey;
if(typeof data3 === "string"){
if(func1(data3) > 256){
const err12 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err12];
}
else {
vErrors.push(err12);
}
errors++;
}
if(func1(data3) < 1){
const err13 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
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
const err14 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err14];
}
else {
vErrors.push(err14);
}
errors++;
}
}
if(data.requestedAction !== undefined){
let data4 = data.requestedAction;
if(typeof data4 !== "string"){
const err15 = {instancePath:instancePath+"/requestedAction",schemaPath:"#/properties/requestedAction/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err15];
}
else {
vErrors.push(err15);
}
errors++;
}
if(!(((data4 === "save") || (data4 === "summarize")) || (data4 === "translate"))){
const err16 = {instancePath:instancePath+"/requestedAction",schemaPath:"#/properties/requestedAction/enum",keyword:"enum",params:{allowedValues: schema32.properties.requestedAction.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err16];
}
else {
vErrors.push(err16);
}
errors++;
}
}
if(data.source !== undefined){
let data5 = data.source;
if(data5 && typeof data5 == "object" && !Array.isArray(data5)){
if(data5.kind === undefined){
const err17 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err17];
}
else {
vErrors.push(err17);
}
errors++;
}
if(data5.url === undefined){
const err18 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "url"},message:"must have required property '"+"url"+"'"};
if(vErrors === null){
vErrors = [err18];
}
else {
vErrors.push(err18);
}
errors++;
}
if(data5.title === undefined){
const err19 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "title"},message:"must have required property '"+"title"+"'"};
if(vErrors === null){
vErrors = [err19];
}
else {
vErrors.push(err19);
}
errors++;
}
if(data5.platform === undefined){
const err20 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "platform"},message:"must have required property '"+"platform"+"'"};
if(vErrors === null){
vErrors = [err20];
}
else {
vErrors.push(err20);
}
errors++;
}
if(data5.kind !== undefined){
if("browser_capture" !== data5.kind){
const err21 = {instancePath:instancePath+"/source/kind",schemaPath:"#/properties/source/properties/kind/const",keyword:"const",params:{allowedValue: "browser_capture"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err21];
}
else {
vErrors.push(err21);
}
errors++;
}
}
if(data5.url !== undefined){
let data7 = data5.url;
if(typeof data7 === "string"){
if(func1(data7) > 8192){
const err22 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err22];
}
else {
vErrors.push(err22);
}
errors++;
}
if(!pattern4.test(data7)){
const err23 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/pattern",keyword:"pattern",params:{pattern: "^https?://"},message:"must match pattern \""+"^https?://"+"\""};
if(vErrors === null){
vErrors = [err23];
}
else {
vErrors.push(err23);
}
errors++;
}
if(!(formats2(data7))){
const err24 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err24];
}
else {
vErrors.push(err24);
}
errors++;
}
}
else {
const err25 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err25];
}
else {
vErrors.push(err25);
}
errors++;
}
}
if(data5.title !== undefined){
let data8 = data5.title;
if((typeof data8 !== "string") && (data8 !== null)){
const err26 = {instancePath:instancePath+"/source/title",schemaPath:"#/properties/source/properties/title/type",keyword:"type",params:{type: schema32.properties.source.properties.title.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err26];
}
else {
vErrors.push(err26);
}
errors++;
}
if(typeof data8 === "string"){
if(func1(data8) > 1024){
const err27 = {instancePath:instancePath+"/source/title",schemaPath:"#/properties/source/properties/title/maxLength",keyword:"maxLength",params:{limit: 1024},message:"must NOT have more than 1024 characters"};
if(vErrors === null){
vErrors = [err27];
}
else {
vErrors.push(err27);
}
errors++;
}
}
}
if(data5.platform !== undefined){
let data9 = data5.platform;
if(typeof data9 !== "string"){
const err28 = {instancePath:instancePath+"/source/platform",schemaPath:"#/properties/source/properties/platform/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err28];
}
else {
vErrors.push(err28);
}
errors++;
}
if(!((((((((((((data9 === "generic") || (data9 === "x")) || (data9 === "youtube")) || (data9 === "wechat")) || (data9 === "xiaohongshu")) || (data9 === "douyin")) || (data9 === "bilibili")) || (data9 === "github")) || (data9 === "zhihu")) || (data9 === "medium")) || (data9 === "substack")) || (data9 === "toutiao"))){
const err29 = {instancePath:instancePath+"/source/platform",schemaPath:"#/properties/source/properties/platform/enum",keyword:"enum",params:{allowedValues: schema32.properties.source.properties.platform.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err29];
}
else {
vErrors.push(err29);
}
errors++;
}
}
}
else {
const err30 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err30];
}
else {
vErrors.push(err30);
}
errors++;
}
}
if(data.capture !== undefined){
let data10 = data.capture;
if(data10 && typeof data10 == "object" && !Array.isArray(data10)){
if(data10.method === undefined){
const err31 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "method"},message:"must have required property '"+"method"+"'"};
if(vErrors === null){
vErrors = [err31];
}
else {
vErrors.push(err31);
}
errors++;
}
if(data10.text === undefined){
const err32 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "text"},message:"must have required property '"+"text"+"'"};
if(vErrors === null){
vErrors = [err32];
}
else {
vErrors.push(err32);
}
errors++;
}
if(data10.characterCount === undefined){
const err33 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "characterCount"},message:"must have required property '"+"characterCount"+"'"};
if(vErrors === null){
vErrors = [err33];
}
else {
vErrors.push(err33);
}
errors++;
}
if(data10.completeness === undefined){
const err34 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "completeness"},message:"must have required property '"+"completeness"+"'"};
if(vErrors === null){
vErrors = [err34];
}
else {
vErrors.push(err34);
}
errors++;
}
if(data10.capturedAt === undefined){
const err35 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "capturedAt"},message:"must have required property '"+"capturedAt"+"'"};
if(vErrors === null){
vErrors = [err35];
}
else {
vErrors.push(err35);
}
errors++;
}
if(data10.method !== undefined){
let data11 = data10.method;
if(typeof data11 !== "string"){
const err36 = {instancePath:instancePath+"/capture/method",schemaPath:"#/properties/capture/properties/method/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err36];
}
else {
vErrors.push(err36);
}
errors++;
}
if(!((data11 === "rendered_dom") || (data11 === "selection"))){
const err37 = {instancePath:instancePath+"/capture/method",schemaPath:"#/properties/capture/properties/method/enum",keyword:"enum",params:{allowedValues: schema32.properties.capture.properties.method.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err37];
}
else {
vErrors.push(err37);
}
errors++;
}
}
if(data10.text !== undefined){
let data12 = data10.text;
if(typeof data12 === "string"){
if(func1(data12) > 2000000){
const err38 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/maxLength",keyword:"maxLength",params:{limit: 2000000},message:"must NOT have more than 2000000 characters"};
if(vErrors === null){
vErrors = [err38];
}
else {
vErrors.push(err38);
}
errors++;
}
if(func1(data12) < 1){
const err39 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err39];
}
else {
vErrors.push(err39);
}
errors++;
}
}
else {
const err40 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err40];
}
else {
vErrors.push(err40);
}
errors++;
}
}
if(data10.characterCount !== undefined){
let data13 = data10.characterCount;
if(!((typeof data13 == "number") && (!(data13 % 1) && !isNaN(data13)))){
const err41 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/type",keyword:"type",params:{type: "integer"},message:"must be integer"};
if(vErrors === null){
vErrors = [err41];
}
else {
vErrors.push(err41);
}
errors++;
}
if(typeof data13 == "number"){
if(data13 > 2000000 || isNaN(data13)){
const err42 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/maximum",keyword:"maximum",params:{comparison: "<=", limit: 2000000},message:"must be <= 2000000"};
if(vErrors === null){
vErrors = [err42];
}
else {
vErrors.push(err42);
}
errors++;
}
if(data13 < 1 || isNaN(data13)){
const err43 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/minimum",keyword:"minimum",params:{comparison: ">=", limit: 1},message:"must be >= 1"};
if(vErrors === null){
vErrors = [err43];
}
else {
vErrors.push(err43);
}
errors++;
}
}
}
if(data10.completeness !== undefined){
let data14 = data10.completeness;
if(typeof data14 !== "string"){
const err44 = {instancePath:instancePath+"/capture/completeness",schemaPath:"#/properties/capture/properties/completeness/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err44];
}
else {
vErrors.push(err44);
}
errors++;
}
if(!((((data14 === "full_article") || (data14 === "visible_only")) || (data14 === "selection_only")) || (data14 === "unknown"))){
const err45 = {instancePath:instancePath+"/capture/completeness",schemaPath:"#/properties/capture/properties/completeness/enum",keyword:"enum",params:{allowedValues: schema32.properties.capture.properties.completeness.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err45];
}
else {
vErrors.push(err45);
}
errors++;
}
}
if(data10.capturedAt !== undefined){
let data15 = data10.capturedAt;
if(typeof data15 === "string"){
if(!(formats0.validate(data15))){
const err46 = {instancePath:instancePath+"/capture/capturedAt",schemaPath:"#/properties/capture/properties/capturedAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
if(vErrors === null){
vErrors = [err46];
}
else {
vErrors.push(err46);
}
errors++;
}
}
else {
const err47 = {instancePath:instancePath+"/capture/capturedAt",schemaPath:"#/properties/capture/properties/capturedAt/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err47];
}
else {
vErrors.push(err47);
}
errors++;
}
}
}
else {
const err48 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err48];
}
else {
vErrors.push(err48);
}
errors++;
}
}
if(data.evidence !== undefined){
let data16 = data.evidence;
if(data16 && typeof data16 == "object" && !Array.isArray(data16)){
if(data16.sourceLabel === undefined){
const err49 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/required",keyword:"required",params:{missingProperty: "sourceLabel"},message:"must have required property '"+"sourceLabel"+"'"};
if(vErrors === null){
vErrors = [err49];
}
else {
vErrors.push(err49);
}
errors++;
}
if(data16.usedCookie === undefined){
const err50 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/required",keyword:"required",params:{missingProperty: "usedCookie"},message:"must have required property '"+"usedCookie"+"'"};
if(vErrors === null){
vErrors = [err50];
}
else {
vErrors.push(err50);
}
errors++;
}
if(data16.sourceLabel !== undefined){
let data17 = data16.sourceLabel;
if(typeof data17 === "string"){
if(func1(data17) > 128){
const err51 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err51];
}
else {
vErrors.push(err51);
}
errors++;
}
if(func1(data17) < 1){
const err52 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err52];
}
else {
vErrors.push(err52);
}
errors++;
}
}
else {
const err53 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err53];
}
else {
vErrors.push(err53);
}
errors++;
}
}
if(data16.usedCookie !== undefined){
if(false !== data16.usedCookie){
const err54 = {instancePath:instancePath+"/evidence/usedCookie",schemaPath:"#/properties/evidence/properties/usedCookie/const",keyword:"const",params:{allowedValue: false},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err54];
}
else {
vErrors.push(err54);
}
errors++;
}
}
}
else {
const err55 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err55];
}
else {
vErrors.push(err55);
}
errors++;
}
}
if(data.media !== undefined){
let data19 = data.media;
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
if(data19.platform === undefined){
const err56 = {instancePath:instancePath+"/media",schemaPath:"#/properties/media/required",keyword:"required",params:{missingProperty: "platform"},message:"must have required property '"+"platform"+"'"};
if(vErrors === null){
vErrors = [err56];
}
else {
vErrors.push(err56);
}
errors++;
}
if(data19.videoURL === undefined){
const err57 = {instancePath:instancePath+"/media",schemaPath:"#/properties/media/required",keyword:"required",params:{missingProperty: "videoURL"},message:"must have required property '"+"videoURL"+"'"};
if(vErrors === null){
vErrors = [err57];
}
else {
vErrors.push(err57);
}
errors++;
}
if(data19.platform !== undefined){
let data20 = data19.platform;
if(typeof data20 !== "string"){
const err58 = {instancePath:instancePath+"/media/platform",schemaPath:"#/properties/media/properties/platform/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err58];
}
else {
vErrors.push(err58);
}
errors++;
}
if(!(data20 === "douyin")){
const err59 = {instancePath:instancePath+"/media/platform",schemaPath:"#/properties/media/properties/platform/enum",keyword:"enum",params:{allowedValues: schema32.properties.media.properties.platform.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err59];
}
else {
vErrors.push(err59);
}
errors++;
}
}
if(data19.videoURL !== undefined){
let data21 = data19.videoURL;
if(typeof data21 === "string"){
if(func1(data21) > 8192){
const err60 = {instancePath:instancePath+"/media/videoURL",schemaPath:"#/properties/media/properties/videoURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err60];
}
else {
vErrors.push(err60);
}
errors++;
}
if(!pattern5.test(data21)){
const err61 = {instancePath:instancePath+"/media/videoURL",schemaPath:"#/properties/media/properties/videoURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err61];
}
else {
vErrors.push(err61);
}
errors++;
}
if(!(formats2(data21))){
const err62 = {instancePath:instancePath+"/media/videoURL",schemaPath:"#/properties/media/properties/videoURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err62];
}
else {
vErrors.push(err62);
}
errors++;
}
}
else {
const err63 = {instancePath:instancePath+"/media/videoURL",schemaPath:"#/properties/media/properties/videoURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err63];
}
else {
vErrors.push(err63);
}
errors++;
}
}
if(data19.coverURL !== undefined){
let data22 = data19.coverURL;
if((typeof data22 !== "string") && (data22 !== null)){
const err64 = {instancePath:instancePath+"/media/coverURL",schemaPath:"#/properties/media/properties/coverURL/type",keyword:"type",params:{type: schema32.properties.media.properties.coverURL.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err64];
}
else {
vErrors.push(err64);
}
errors++;
}
if(typeof data22 === "string"){
if(func1(data22) > 8192){
const err65 = {instancePath:instancePath+"/media/coverURL",schemaPath:"#/properties/media/properties/coverURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err65];
}
else {
vErrors.push(err65);
}
errors++;
}
if(!pattern5.test(data22)){
const err66 = {instancePath:instancePath+"/media/coverURL",schemaPath:"#/properties/media/properties/coverURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err66];
}
else {
vErrors.push(err66);
}
errors++;
}
if(!(formats2(data22))){
const err67 = {instancePath:instancePath+"/media/coverURL",schemaPath:"#/properties/media/properties/coverURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err67];
}
else {
vErrors.push(err67);
}
errors++;
}
}
}
if(data19.durationSeconds !== undefined){
let data23 = data19.durationSeconds;
if((!(typeof data23 == "number")) && (data23 !== null)){
const err68 = {instancePath:instancePath+"/media/durationSeconds",schemaPath:"#/properties/media/properties/durationSeconds/type",keyword:"type",params:{type: schema32.properties.media.properties.durationSeconds.type},message:"must be number,null"};
if(vErrors === null){
vErrors = [err68];
}
else {
vErrors.push(err68);
}
errors++;
}
if(typeof data23 == "number"){
if(data23 > 86400 || isNaN(data23)){
const err69 = {instancePath:instancePath+"/media/durationSeconds",schemaPath:"#/properties/media/properties/durationSeconds/maximum",keyword:"maximum",params:{comparison: "<=", limit: 86400},message:"must be <= 86400"};
if(vErrors === null){
vErrors = [err69];
}
else {
vErrors.push(err69);
}
errors++;
}
if(data23 < 0 || isNaN(data23)){
const err70 = {instancePath:instancePath+"/media/durationSeconds",schemaPath:"#/properties/media/properties/durationSeconds/minimum",keyword:"minimum",params:{comparison: ">=", limit: 0},message:"must be >= 0"};
if(vErrors === null){
vErrors = [err70];
}
else {
vErrors.push(err70);
}
errors++;
}
}
}
if(data19.author !== undefined){
let data24 = data19.author;
if((typeof data24 !== "string") && (data24 !== null)){
const err71 = {instancePath:instancePath+"/media/author",schemaPath:"#/properties/media/properties/author/type",keyword:"type",params:{type: schema32.properties.media.properties.author.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err71];
}
else {
vErrors.push(err71);
}
errors++;
}
if(typeof data24 === "string"){
if(func1(data24) > 256){
const err72 = {instancePath:instancePath+"/media/author",schemaPath:"#/properties/media/properties/author/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err72];
}
else {
vErrors.push(err72);
}
errors++;
}
}
}
}
else {
const err73 = {instancePath:instancePath+"/media",schemaPath:"#/properties/media/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err73];
}
else {
vErrors.push(err73);
}
errors++;
}
}
}
else {
const err74 = {instancePath,schemaPath:"#/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err74];
}
else {
vErrors.push(err74);
}
errors++;
}
validate21.errors = vErrors;
return errors === 0;
}
validate21.evaluated = {"props":true,"dynamicProps":false,"dynamicItems":false};

const schema33 = {"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://syc.local/linkdigest/capture-envelope-v2.schema.json","title":"LinkDigest Capture Envelope V2","description":"Independent V2 browser capture contract. Media playback addresses are process-memory handoff values and must never be persisted, logged, exported, fingerprinted, or committed as real signed fixture URLs.","type":"object","required":["version","requestId","createdAt","source","capture","evidence","media"],"additionalProperties":true,"properties":{"version":{"const":2},"requestId":{"type":"string","minLength":1,"maxLength":128},"createdAt":{"type":"string","format":"date-time"},"idempotencyKey":{"type":"string","minLength":1,"maxLength":256},"requestedAction":{"type":"string","enum":["save","summarize","translate"]},"source":{"type":"object","required":["kind","url","title","platform"],"additionalProperties":true,"properties":{"kind":{"const":"browser_capture"},"url":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"title":{"type":["string","null"],"maxLength":1024},"platform":{"type":"string","enum":["generic","x","youtube","wechat","xiaohongshu","douyin","bilibili","github","zhihu","medium","substack","toutiao"]}}},"capture":{"type":"object","required":["method","text","characterCount","completeness","capturedAt"],"additionalProperties":true,"properties":{"method":{"type":"string","enum":["rendered_dom","selection"]},"text":{"type":"string","minLength":1,"maxLength":2000000},"characterCount":{"type":"integer","minimum":1,"maximum":2000000},"completeness":{"type":"string","enum":["full_article","visible_only","selection_only","unknown"]},"capturedAt":{"type":"string","format":"date-time"}}},"evidence":{"type":"object","required":["sourceLabel","usedCookie"],"additionalProperties":true,"properties":{"sourceLabel":{"type":"string","minLength":1,"maxLength":128},"usedCookie":{"type":"boolean"}}},"media":{"$ref":"#/$defs/MediaDescriptor"}},"$defs":{"MediaDescriptor":{"type":"object","required":["kind","pageURL","canonicalURL","platform","transcriptionCapability"],"additionalProperties":true,"properties":{"kind":{"type":"string","enum":["directFile","hls","embed","browserSessionOnly","unsupported"]},"pageURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"canonicalURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"platform":{"type":"string","enum":["generic","x","youtube","wechat","xiaohongshu","douyin","bilibili","github","zhihu","medium","substack","toutiao"]},"ephemeralPlaybackURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https://"},"companionAudioURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https://"},"mimeType":{"type":["string","null"],"maxLength":256},"posterURL":{"type":["string","null"],"format":"uri","maxLength":8192,"pattern":"^https://"},"durationSeconds":{"type":["number","null"],"minimum":0,"maximum":86400},"author":{"type":["string","null"],"maxLength":256},"expiresAt":{"type":["string","null"],"format":"date-time"},"transcriptionCapability":{"type":"string","enum":["supported","conditional","unavailable"]},"failureReason":{"type":"string","enum":["blob_or_mse","multiple_candidates","video_not_loaded","no_transferable_source","drm_or_encrypted","browser_session_required","unsupported_media_type","unknown"]},"candidateCount":{"type":"integer","minimum":1,"maximum":1000},"selectionReason":{"type":"string","enum":["singleCandidate","playing","recentInteraction","largestVisibleArea","nearestViewportCenter","ambiguous"]},"playbackState":{"type":"string","enum":["playing","paused","ended","notLoaded","unknown"]}},"oneOf":[{"required":["kind","ephemeralPlaybackURL"],"properties":{"kind":{"const":"directFile"}},"not":{"required":["failureReason"]}},{"required":["kind","ephemeralPlaybackURL"],"properties":{"kind":{"const":"hls"}},"not":{"required":["failureReason"]}},{"required":["kind"],"properties":{"kind":{"const":"embed"}},"not":{"required":["ephemeralPlaybackURL"]}},{"required":["kind","failureReason"],"properties":{"kind":{"const":"browserSessionOnly"}},"not":{"required":["ephemeralPlaybackURL"]}},{"required":["kind","failureReason"],"properties":{"kind":{"const":"unsupported"}},"not":{"required":["ephemeralPlaybackURL"]}}]}},"x-semantic-invariants":["capture.characterCount equals the Unicode code point count of capture.text","directFile and hls require an HTTPS ephemeralPlaybackURL and forbid failureReason","browserSessionOnly and unsupported forbid ephemeralPlaybackURL and require failureReason","ephemeralPlaybackURL is process-memory-only and excluded from persistence, logs, exports, errors, and persistent fingerprints"]};
const schema34 = {"type":"object","required":["kind","pageURL","canonicalURL","platform","transcriptionCapability"],"additionalProperties":true,"properties":{"kind":{"type":"string","enum":["directFile","hls","embed","browserSessionOnly","unsupported"]},"pageURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"canonicalURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https?://"},"platform":{"type":"string","enum":["generic","x","youtube","wechat","xiaohongshu","douyin","bilibili","github","zhihu","medium","substack","toutiao"]},"ephemeralPlaybackURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https://"},"companionAudioURL":{"type":"string","format":"uri","maxLength":8192,"pattern":"^https://"},"mimeType":{"type":["string","null"],"maxLength":256},"posterURL":{"type":["string","null"],"format":"uri","maxLength":8192,"pattern":"^https://"},"durationSeconds":{"type":["number","null"],"minimum":0,"maximum":86400},"author":{"type":["string","null"],"maxLength":256},"expiresAt":{"type":["string","null"],"format":"date-time"},"transcriptionCapability":{"type":"string","enum":["supported","conditional","unavailable"]},"failureReason":{"type":"string","enum":["blob_or_mse","multiple_candidates","video_not_loaded","no_transferable_source","drm_or_encrypted","browser_session_required","unsupported_media_type","unknown"]},"candidateCount":{"type":"integer","minimum":1,"maximum":1000},"selectionReason":{"type":"string","enum":["singleCandidate","playing","recentInteraction","largestVisibleArea","nearestViewportCenter","ambiguous"]},"playbackState":{"type":"string","enum":["playing","paused","ended","notLoaded","unknown"]}},"oneOf":[{"required":["kind","ephemeralPlaybackURL"],"properties":{"kind":{"const":"directFile"}},"not":{"required":["failureReason"]}},{"required":["kind","ephemeralPlaybackURL"],"properties":{"kind":{"const":"hls"}},"not":{"required":["failureReason"]}},{"required":["kind"],"properties":{"kind":{"const":"embed"}},"not":{"required":["ephemeralPlaybackURL"]}},{"required":["kind","failureReason"],"properties":{"kind":{"const":"browserSessionOnly"}},"not":{"required":["ephemeralPlaybackURL"]}},{"required":["kind","failureReason"],"properties":{"kind":{"const":"unsupported"}},"not":{"required":["ephemeralPlaybackURL"]}}]};

function validate23(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
/*# sourceURL="https://syc.local/linkdigest/capture-envelope-v2.schema.json" */;
let vErrors = null;
let errors = 0;
const evaluated0 = validate23.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
if(data && typeof data == "object" && !Array.isArray(data)){
if(data.version === undefined){
const err0 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "version"},message:"must have required property '"+"version"+"'"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
if(data.requestId === undefined){
const err1 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "requestId"},message:"must have required property '"+"requestId"+"'"};
if(vErrors === null){
vErrors = [err1];
}
else {
vErrors.push(err1);
}
errors++;
}
if(data.createdAt === undefined){
const err2 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "createdAt"},message:"must have required property '"+"createdAt"+"'"};
if(vErrors === null){
vErrors = [err2];
}
else {
vErrors.push(err2);
}
errors++;
}
if(data.source === undefined){
const err3 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "source"},message:"must have required property '"+"source"+"'"};
if(vErrors === null){
vErrors = [err3];
}
else {
vErrors.push(err3);
}
errors++;
}
if(data.capture === undefined){
const err4 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "capture"},message:"must have required property '"+"capture"+"'"};
if(vErrors === null){
vErrors = [err4];
}
else {
vErrors.push(err4);
}
errors++;
}
if(data.evidence === undefined){
const err5 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "evidence"},message:"must have required property '"+"evidence"+"'"};
if(vErrors === null){
vErrors = [err5];
}
else {
vErrors.push(err5);
}
errors++;
}
if(data.media === undefined){
const err6 = {instancePath,schemaPath:"#/required",keyword:"required",params:{missingProperty: "media"},message:"must have required property '"+"media"+"'"};
if(vErrors === null){
vErrors = [err6];
}
else {
vErrors.push(err6);
}
errors++;
}
if(data.version !== undefined){
if(2 !== data.version){
const err7 = {instancePath:instancePath+"/version",schemaPath:"#/properties/version/const",keyword:"const",params:{allowedValue: 2},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err7];
}
else {
vErrors.push(err7);
}
errors++;
}
}
if(data.requestId !== undefined){
let data1 = data.requestId;
if(typeof data1 === "string"){
if(func1(data1) > 128){
const err8 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err8];
}
else {
vErrors.push(err8);
}
errors++;
}
if(func1(data1) < 1){
const err9 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err9];
}
else {
vErrors.push(err9);
}
errors++;
}
}
else {
const err10 = {instancePath:instancePath+"/requestId",schemaPath:"#/properties/requestId/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err10];
}
else {
vErrors.push(err10);
}
errors++;
}
}
if(data.createdAt !== undefined){
let data2 = data.createdAt;
if(typeof data2 === "string"){
if(!(formats0.validate(data2))){
const err11 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
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
const err12 = {instancePath:instancePath+"/createdAt",schemaPath:"#/properties/createdAt/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err12];
}
else {
vErrors.push(err12);
}
errors++;
}
}
if(data.idempotencyKey !== undefined){
let data3 = data.idempotencyKey;
if(typeof data3 === "string"){
if(func1(data3) > 256){
const err13 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err13];
}
else {
vErrors.push(err13);
}
errors++;
}
if(func1(data3) < 1){
const err14 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err14];
}
else {
vErrors.push(err14);
}
errors++;
}
}
else {
const err15 = {instancePath:instancePath+"/idempotencyKey",schemaPath:"#/properties/idempotencyKey/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err15];
}
else {
vErrors.push(err15);
}
errors++;
}
}
if(data.requestedAction !== undefined){
let data4 = data.requestedAction;
if(typeof data4 !== "string"){
const err16 = {instancePath:instancePath+"/requestedAction",schemaPath:"#/properties/requestedAction/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err16];
}
else {
vErrors.push(err16);
}
errors++;
}
if(!(((data4 === "save") || (data4 === "summarize")) || (data4 === "translate"))){
const err17 = {instancePath:instancePath+"/requestedAction",schemaPath:"#/properties/requestedAction/enum",keyword:"enum",params:{allowedValues: schema33.properties.requestedAction.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err17];
}
else {
vErrors.push(err17);
}
errors++;
}
}
if(data.source !== undefined){
let data5 = data.source;
if(data5 && typeof data5 == "object" && !Array.isArray(data5)){
if(data5.kind === undefined){
const err18 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err18];
}
else {
vErrors.push(err18);
}
errors++;
}
if(data5.url === undefined){
const err19 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "url"},message:"must have required property '"+"url"+"'"};
if(vErrors === null){
vErrors = [err19];
}
else {
vErrors.push(err19);
}
errors++;
}
if(data5.title === undefined){
const err20 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "title"},message:"must have required property '"+"title"+"'"};
if(vErrors === null){
vErrors = [err20];
}
else {
vErrors.push(err20);
}
errors++;
}
if(data5.platform === undefined){
const err21 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/required",keyword:"required",params:{missingProperty: "platform"},message:"must have required property '"+"platform"+"'"};
if(vErrors === null){
vErrors = [err21];
}
else {
vErrors.push(err21);
}
errors++;
}
if(data5.kind !== undefined){
if("browser_capture" !== data5.kind){
const err22 = {instancePath:instancePath+"/source/kind",schemaPath:"#/properties/source/properties/kind/const",keyword:"const",params:{allowedValue: "browser_capture"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err22];
}
else {
vErrors.push(err22);
}
errors++;
}
}
if(data5.url !== undefined){
let data7 = data5.url;
if(typeof data7 === "string"){
if(func1(data7) > 8192){
const err23 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err23];
}
else {
vErrors.push(err23);
}
errors++;
}
if(!pattern4.test(data7)){
const err24 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/pattern",keyword:"pattern",params:{pattern: "^https?://"},message:"must match pattern \""+"^https?://"+"\""};
if(vErrors === null){
vErrors = [err24];
}
else {
vErrors.push(err24);
}
errors++;
}
if(!(formats2(data7))){
const err25 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err25];
}
else {
vErrors.push(err25);
}
errors++;
}
}
else {
const err26 = {instancePath:instancePath+"/source/url",schemaPath:"#/properties/source/properties/url/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err26];
}
else {
vErrors.push(err26);
}
errors++;
}
}
if(data5.title !== undefined){
let data8 = data5.title;
if((typeof data8 !== "string") && (data8 !== null)){
const err27 = {instancePath:instancePath+"/source/title",schemaPath:"#/properties/source/properties/title/type",keyword:"type",params:{type: schema33.properties.source.properties.title.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err27];
}
else {
vErrors.push(err27);
}
errors++;
}
if(typeof data8 === "string"){
if(func1(data8) > 1024){
const err28 = {instancePath:instancePath+"/source/title",schemaPath:"#/properties/source/properties/title/maxLength",keyword:"maxLength",params:{limit: 1024},message:"must NOT have more than 1024 characters"};
if(vErrors === null){
vErrors = [err28];
}
else {
vErrors.push(err28);
}
errors++;
}
}
}
if(data5.platform !== undefined){
let data9 = data5.platform;
if(typeof data9 !== "string"){
const err29 = {instancePath:instancePath+"/source/platform",schemaPath:"#/properties/source/properties/platform/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err29];
}
else {
vErrors.push(err29);
}
errors++;
}
if(!((((((((((((data9 === "generic") || (data9 === "x")) || (data9 === "youtube")) || (data9 === "wechat")) || (data9 === "xiaohongshu")) || (data9 === "douyin")) || (data9 === "bilibili")) || (data9 === "github")) || (data9 === "zhihu")) || (data9 === "medium")) || (data9 === "substack")) || (data9 === "toutiao"))){
const err30 = {instancePath:instancePath+"/source/platform",schemaPath:"#/properties/source/properties/platform/enum",keyword:"enum",params:{allowedValues: schema33.properties.source.properties.platform.enum},message:"must be equal to one of the allowed values"};
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
else {
const err31 = {instancePath:instancePath+"/source",schemaPath:"#/properties/source/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err31];
}
else {
vErrors.push(err31);
}
errors++;
}
}
if(data.capture !== undefined){
let data10 = data.capture;
if(data10 && typeof data10 == "object" && !Array.isArray(data10)){
if(data10.method === undefined){
const err32 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "method"},message:"must have required property '"+"method"+"'"};
if(vErrors === null){
vErrors = [err32];
}
else {
vErrors.push(err32);
}
errors++;
}
if(data10.text === undefined){
const err33 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "text"},message:"must have required property '"+"text"+"'"};
if(vErrors === null){
vErrors = [err33];
}
else {
vErrors.push(err33);
}
errors++;
}
if(data10.characterCount === undefined){
const err34 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "characterCount"},message:"must have required property '"+"characterCount"+"'"};
if(vErrors === null){
vErrors = [err34];
}
else {
vErrors.push(err34);
}
errors++;
}
if(data10.completeness === undefined){
const err35 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "completeness"},message:"must have required property '"+"completeness"+"'"};
if(vErrors === null){
vErrors = [err35];
}
else {
vErrors.push(err35);
}
errors++;
}
if(data10.capturedAt === undefined){
const err36 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/required",keyword:"required",params:{missingProperty: "capturedAt"},message:"must have required property '"+"capturedAt"+"'"};
if(vErrors === null){
vErrors = [err36];
}
else {
vErrors.push(err36);
}
errors++;
}
if(data10.method !== undefined){
let data11 = data10.method;
if(typeof data11 !== "string"){
const err37 = {instancePath:instancePath+"/capture/method",schemaPath:"#/properties/capture/properties/method/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err37];
}
else {
vErrors.push(err37);
}
errors++;
}
if(!((data11 === "rendered_dom") || (data11 === "selection"))){
const err38 = {instancePath:instancePath+"/capture/method",schemaPath:"#/properties/capture/properties/method/enum",keyword:"enum",params:{allowedValues: schema33.properties.capture.properties.method.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err38];
}
else {
vErrors.push(err38);
}
errors++;
}
}
if(data10.text !== undefined){
let data12 = data10.text;
if(typeof data12 === "string"){
if(func1(data12) > 2000000){
const err39 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/maxLength",keyword:"maxLength",params:{limit: 2000000},message:"must NOT have more than 2000000 characters"};
if(vErrors === null){
vErrors = [err39];
}
else {
vErrors.push(err39);
}
errors++;
}
if(func1(data12) < 1){
const err40 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err40];
}
else {
vErrors.push(err40);
}
errors++;
}
}
else {
const err41 = {instancePath:instancePath+"/capture/text",schemaPath:"#/properties/capture/properties/text/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err41];
}
else {
vErrors.push(err41);
}
errors++;
}
}
if(data10.characterCount !== undefined){
let data13 = data10.characterCount;
if(!((typeof data13 == "number") && (!(data13 % 1) && !isNaN(data13)))){
const err42 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/type",keyword:"type",params:{type: "integer"},message:"must be integer"};
if(vErrors === null){
vErrors = [err42];
}
else {
vErrors.push(err42);
}
errors++;
}
if(typeof data13 == "number"){
if(data13 > 2000000 || isNaN(data13)){
const err43 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/maximum",keyword:"maximum",params:{comparison: "<=", limit: 2000000},message:"must be <= 2000000"};
if(vErrors === null){
vErrors = [err43];
}
else {
vErrors.push(err43);
}
errors++;
}
if(data13 < 1 || isNaN(data13)){
const err44 = {instancePath:instancePath+"/capture/characterCount",schemaPath:"#/properties/capture/properties/characterCount/minimum",keyword:"minimum",params:{comparison: ">=", limit: 1},message:"must be >= 1"};
if(vErrors === null){
vErrors = [err44];
}
else {
vErrors.push(err44);
}
errors++;
}
}
}
if(data10.completeness !== undefined){
let data14 = data10.completeness;
if(typeof data14 !== "string"){
const err45 = {instancePath:instancePath+"/capture/completeness",schemaPath:"#/properties/capture/properties/completeness/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err45];
}
else {
vErrors.push(err45);
}
errors++;
}
if(!((((data14 === "full_article") || (data14 === "visible_only")) || (data14 === "selection_only")) || (data14 === "unknown"))){
const err46 = {instancePath:instancePath+"/capture/completeness",schemaPath:"#/properties/capture/properties/completeness/enum",keyword:"enum",params:{allowedValues: schema33.properties.capture.properties.completeness.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err46];
}
else {
vErrors.push(err46);
}
errors++;
}
}
if(data10.capturedAt !== undefined){
let data15 = data10.capturedAt;
if(typeof data15 === "string"){
if(!(formats0.validate(data15))){
const err47 = {instancePath:instancePath+"/capture/capturedAt",schemaPath:"#/properties/capture/properties/capturedAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
if(vErrors === null){
vErrors = [err47];
}
else {
vErrors.push(err47);
}
errors++;
}
}
else {
const err48 = {instancePath:instancePath+"/capture/capturedAt",schemaPath:"#/properties/capture/properties/capturedAt/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err48];
}
else {
vErrors.push(err48);
}
errors++;
}
}
}
else {
const err49 = {instancePath:instancePath+"/capture",schemaPath:"#/properties/capture/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err49];
}
else {
vErrors.push(err49);
}
errors++;
}
}
if(data.evidence !== undefined){
let data16 = data.evidence;
if(data16 && typeof data16 == "object" && !Array.isArray(data16)){
if(data16.sourceLabel === undefined){
const err50 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/required",keyword:"required",params:{missingProperty: "sourceLabel"},message:"must have required property '"+"sourceLabel"+"'"};
if(vErrors === null){
vErrors = [err50];
}
else {
vErrors.push(err50);
}
errors++;
}
if(data16.usedCookie === undefined){
const err51 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/required",keyword:"required",params:{missingProperty: "usedCookie"},message:"must have required property '"+"usedCookie"+"'"};
if(vErrors === null){
vErrors = [err51];
}
else {
vErrors.push(err51);
}
errors++;
}
if(data16.sourceLabel !== undefined){
let data17 = data16.sourceLabel;
if(typeof data17 === "string"){
if(func1(data17) > 128){
const err52 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/maxLength",keyword:"maxLength",params:{limit: 128},message:"must NOT have more than 128 characters"};
if(vErrors === null){
vErrors = [err52];
}
else {
vErrors.push(err52);
}
errors++;
}
if(func1(data17) < 1){
const err53 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/minLength",keyword:"minLength",params:{limit: 1},message:"must NOT have fewer than 1 characters"};
if(vErrors === null){
vErrors = [err53];
}
else {
vErrors.push(err53);
}
errors++;
}
}
else {
const err54 = {instancePath:instancePath+"/evidence/sourceLabel",schemaPath:"#/properties/evidence/properties/sourceLabel/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err54];
}
else {
vErrors.push(err54);
}
errors++;
}
}
if(data16.usedCookie !== undefined){
if(typeof data16.usedCookie !== "boolean"){
const err55 = {instancePath:instancePath+"/evidence/usedCookie",schemaPath:"#/properties/evidence/properties/usedCookie/type",keyword:"type",params:{type: "boolean"},message:"must be boolean"};
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
else {
const err56 = {instancePath:instancePath+"/evidence",schemaPath:"#/properties/evidence/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err56];
}
else {
vErrors.push(err56);
}
errors++;
}
}
if(data.media !== undefined){
let data19 = data.media;
const _errs44 = errors;
let valid5 = false;
let passing0 = null;
const _errs45 = errors;
const _errs46 = errors;
const _errs47 = errors;
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
let missing0;
if((data19.failureReason === undefined) && (missing0 = "failureReason")){
const err57 = {};
if(vErrors === null){
vErrors = [err57];
}
else {
vErrors.push(err57);
}
errors++;
}
}
var valid6 = _errs47 === errors;
if(valid6){
const err58 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/0/not",keyword:"not",params:{},message:"must NOT be valid"};
if(vErrors === null){
vErrors = [err58];
}
else {
vErrors.push(err58);
}
errors++;
}
else {
errors = _errs46;
if(vErrors !== null){
if(_errs46){
vErrors.length = _errs46;
}
else {
vErrors = null;
}
}
}
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
if(data19.kind === undefined){
const err59 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/0/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err59];
}
else {
vErrors.push(err59);
}
errors++;
}
if(data19.ephemeralPlaybackURL === undefined){
const err60 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/0/required",keyword:"required",params:{missingProperty: "ephemeralPlaybackURL"},message:"must have required property '"+"ephemeralPlaybackURL"+"'"};
if(vErrors === null){
vErrors = [err60];
}
else {
vErrors.push(err60);
}
errors++;
}
if(data19.kind !== undefined){
if("directFile" !== data19.kind){
const err61 = {instancePath:instancePath+"/media/kind",schemaPath:"#/$defs/MediaDescriptor/oneOf/0/properties/kind/const",keyword:"const",params:{allowedValue: "directFile"},message:"must be equal to constant"};
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
var _valid0 = _errs45 === errors;
if(_valid0){
valid5 = true;
passing0 = 0;
var props0 = {};
props0.kind = true;
}
const _errs49 = errors;
const _errs50 = errors;
const _errs51 = errors;
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
let missing1;
if((data19.failureReason === undefined) && (missing1 = "failureReason")){
const err62 = {};
if(vErrors === null){
vErrors = [err62];
}
else {
vErrors.push(err62);
}
errors++;
}
}
var valid8 = _errs51 === errors;
if(valid8){
const err63 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/1/not",keyword:"not",params:{},message:"must NOT be valid"};
if(vErrors === null){
vErrors = [err63];
}
else {
vErrors.push(err63);
}
errors++;
}
else {
errors = _errs50;
if(vErrors !== null){
if(_errs50){
vErrors.length = _errs50;
}
else {
vErrors = null;
}
}
}
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
if(data19.kind === undefined){
const err64 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/1/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err64];
}
else {
vErrors.push(err64);
}
errors++;
}
if(data19.ephemeralPlaybackURL === undefined){
const err65 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/1/required",keyword:"required",params:{missingProperty: "ephemeralPlaybackURL"},message:"must have required property '"+"ephemeralPlaybackURL"+"'"};
if(vErrors === null){
vErrors = [err65];
}
else {
vErrors.push(err65);
}
errors++;
}
if(data19.kind !== undefined){
if("hls" !== data19.kind){
const err66 = {instancePath:instancePath+"/media/kind",schemaPath:"#/$defs/MediaDescriptor/oneOf/1/properties/kind/const",keyword:"const",params:{allowedValue: "hls"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err66];
}
else {
vErrors.push(err66);
}
errors++;
}
}
}
var _valid0 = _errs49 === errors;
if(_valid0 && valid5){
valid5 = false;
passing0 = [passing0, 1];
}
else {
if(_valid0){
valid5 = true;
passing0 = 1;
if(props0 !== true){
props0 = props0 || {};
props0.kind = true;
}
}
const _errs53 = errors;
const _errs54 = errors;
const _errs55 = errors;
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
let missing2;
if((data19.ephemeralPlaybackURL === undefined) && (missing2 = "ephemeralPlaybackURL")){
const err67 = {};
if(vErrors === null){
vErrors = [err67];
}
else {
vErrors.push(err67);
}
errors++;
}
}
var valid10 = _errs55 === errors;
if(valid10){
const err68 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/2/not",keyword:"not",params:{},message:"must NOT be valid"};
if(vErrors === null){
vErrors = [err68];
}
else {
vErrors.push(err68);
}
errors++;
}
else {
errors = _errs54;
if(vErrors !== null){
if(_errs54){
vErrors.length = _errs54;
}
else {
vErrors = null;
}
}
}
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
if(data19.kind === undefined){
const err69 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/2/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err69];
}
else {
vErrors.push(err69);
}
errors++;
}
if(data19.kind !== undefined){
if("embed" !== data19.kind){
const err70 = {instancePath:instancePath+"/media/kind",schemaPath:"#/$defs/MediaDescriptor/oneOf/2/properties/kind/const",keyword:"const",params:{allowedValue: "embed"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err70];
}
else {
vErrors.push(err70);
}
errors++;
}
}
}
var _valid0 = _errs53 === errors;
if(_valid0 && valid5){
valid5 = false;
passing0 = [passing0, 2];
}
else {
if(_valid0){
valid5 = true;
passing0 = 2;
if(props0 !== true){
props0 = props0 || {};
props0.kind = true;
}
}
const _errs57 = errors;
const _errs58 = errors;
const _errs59 = errors;
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
let missing3;
if((data19.ephemeralPlaybackURL === undefined) && (missing3 = "ephemeralPlaybackURL")){
const err71 = {};
if(vErrors === null){
vErrors = [err71];
}
else {
vErrors.push(err71);
}
errors++;
}
}
var valid12 = _errs59 === errors;
if(valid12){
const err72 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/3/not",keyword:"not",params:{},message:"must NOT be valid"};
if(vErrors === null){
vErrors = [err72];
}
else {
vErrors.push(err72);
}
errors++;
}
else {
errors = _errs58;
if(vErrors !== null){
if(_errs58){
vErrors.length = _errs58;
}
else {
vErrors = null;
}
}
}
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
if(data19.kind === undefined){
const err73 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/3/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err73];
}
else {
vErrors.push(err73);
}
errors++;
}
if(data19.failureReason === undefined){
const err74 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/3/required",keyword:"required",params:{missingProperty: "failureReason"},message:"must have required property '"+"failureReason"+"'"};
if(vErrors === null){
vErrors = [err74];
}
else {
vErrors.push(err74);
}
errors++;
}
if(data19.kind !== undefined){
if("browserSessionOnly" !== data19.kind){
const err75 = {instancePath:instancePath+"/media/kind",schemaPath:"#/$defs/MediaDescriptor/oneOf/3/properties/kind/const",keyword:"const",params:{allowedValue: "browserSessionOnly"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err75];
}
else {
vErrors.push(err75);
}
errors++;
}
}
}
var _valid0 = _errs57 === errors;
if(_valid0 && valid5){
valid5 = false;
passing0 = [passing0, 3];
}
else {
if(_valid0){
valid5 = true;
passing0 = 3;
if(props0 !== true){
props0 = props0 || {};
props0.kind = true;
}
}
const _errs61 = errors;
const _errs62 = errors;
const _errs63 = errors;
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
let missing4;
if((data19.ephemeralPlaybackURL === undefined) && (missing4 = "ephemeralPlaybackURL")){
const err76 = {};
if(vErrors === null){
vErrors = [err76];
}
else {
vErrors.push(err76);
}
errors++;
}
}
var valid14 = _errs63 === errors;
if(valid14){
const err77 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/4/not",keyword:"not",params:{},message:"must NOT be valid"};
if(vErrors === null){
vErrors = [err77];
}
else {
vErrors.push(err77);
}
errors++;
}
else {
errors = _errs62;
if(vErrors !== null){
if(_errs62){
vErrors.length = _errs62;
}
else {
vErrors = null;
}
}
}
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
if(data19.kind === undefined){
const err78 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/4/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err78];
}
else {
vErrors.push(err78);
}
errors++;
}
if(data19.failureReason === undefined){
const err79 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf/4/required",keyword:"required",params:{missingProperty: "failureReason"},message:"must have required property '"+"failureReason"+"'"};
if(vErrors === null){
vErrors = [err79];
}
else {
vErrors.push(err79);
}
errors++;
}
if(data19.kind !== undefined){
if("unsupported" !== data19.kind){
const err80 = {instancePath:instancePath+"/media/kind",schemaPath:"#/$defs/MediaDescriptor/oneOf/4/properties/kind/const",keyword:"const",params:{allowedValue: "unsupported"},message:"must be equal to constant"};
if(vErrors === null){
vErrors = [err80];
}
else {
vErrors.push(err80);
}
errors++;
}
}
}
var _valid0 = _errs61 === errors;
if(_valid0 && valid5){
valid5 = false;
passing0 = [passing0, 4];
}
else {
if(_valid0){
valid5 = true;
passing0 = 4;
if(props0 !== true){
props0 = props0 || {};
props0.kind = true;
}
}
}
}
}
}
if(!valid5){
const err81 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/oneOf",keyword:"oneOf",params:{passingSchemas: passing0},message:"must match exactly one schema in oneOf"};
if(vErrors === null){
vErrors = [err81];
}
else {
vErrors.push(err81);
}
errors++;
}
else {
errors = _errs44;
if(vErrors !== null){
if(_errs44){
vErrors.length = _errs44;
}
else {
vErrors = null;
}
}
}
if(data19 && typeof data19 == "object" && !Array.isArray(data19)){
if(data19.kind === undefined){
const err82 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/required",keyword:"required",params:{missingProperty: "kind"},message:"must have required property '"+"kind"+"'"};
if(vErrors === null){
vErrors = [err82];
}
else {
vErrors.push(err82);
}
errors++;
}
if(data19.pageURL === undefined){
const err83 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/required",keyword:"required",params:{missingProperty: "pageURL"},message:"must have required property '"+"pageURL"+"'"};
if(vErrors === null){
vErrors = [err83];
}
else {
vErrors.push(err83);
}
errors++;
}
if(data19.canonicalURL === undefined){
const err84 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/required",keyword:"required",params:{missingProperty: "canonicalURL"},message:"must have required property '"+"canonicalURL"+"'"};
if(vErrors === null){
vErrors = [err84];
}
else {
vErrors.push(err84);
}
errors++;
}
if(data19.platform === undefined){
const err85 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/required",keyword:"required",params:{missingProperty: "platform"},message:"must have required property '"+"platform"+"'"};
if(vErrors === null){
vErrors = [err85];
}
else {
vErrors.push(err85);
}
errors++;
}
if(data19.transcriptionCapability === undefined){
const err86 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/required",keyword:"required",params:{missingProperty: "transcriptionCapability"},message:"must have required property '"+"transcriptionCapability"+"'"};
if(vErrors === null){
vErrors = [err86];
}
else {
vErrors.push(err86);
}
errors++;
}
if(data19.kind !== undefined){
let data25 = data19.kind;
if(typeof data25 !== "string"){
const err87 = {instancePath:instancePath+"/media/kind",schemaPath:"#/$defs/MediaDescriptor/properties/kind/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err87];
}
else {
vErrors.push(err87);
}
errors++;
}
if(!(((((data25 === "directFile") || (data25 === "hls")) || (data25 === "embed")) || (data25 === "browserSessionOnly")) || (data25 === "unsupported"))){
const err88 = {instancePath:instancePath+"/media/kind",schemaPath:"#/$defs/MediaDescriptor/properties/kind/enum",keyword:"enum",params:{allowedValues: schema34.properties.kind.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err88];
}
else {
vErrors.push(err88);
}
errors++;
}
}
if(data19.pageURL !== undefined){
let data26 = data19.pageURL;
if(typeof data26 === "string"){
if(func1(data26) > 8192){
const err89 = {instancePath:instancePath+"/media/pageURL",schemaPath:"#/$defs/MediaDescriptor/properties/pageURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err89];
}
else {
vErrors.push(err89);
}
errors++;
}
if(!pattern4.test(data26)){
const err90 = {instancePath:instancePath+"/media/pageURL",schemaPath:"#/$defs/MediaDescriptor/properties/pageURL/pattern",keyword:"pattern",params:{pattern: "^https?://"},message:"must match pattern \""+"^https?://"+"\""};
if(vErrors === null){
vErrors = [err90];
}
else {
vErrors.push(err90);
}
errors++;
}
if(!(formats2(data26))){
const err91 = {instancePath:instancePath+"/media/pageURL",schemaPath:"#/$defs/MediaDescriptor/properties/pageURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err91];
}
else {
vErrors.push(err91);
}
errors++;
}
}
else {
const err92 = {instancePath:instancePath+"/media/pageURL",schemaPath:"#/$defs/MediaDescriptor/properties/pageURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err92];
}
else {
vErrors.push(err92);
}
errors++;
}
}
if(data19.canonicalURL !== undefined){
let data27 = data19.canonicalURL;
if(typeof data27 === "string"){
if(func1(data27) > 8192){
const err93 = {instancePath:instancePath+"/media/canonicalURL",schemaPath:"#/$defs/MediaDescriptor/properties/canonicalURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err93];
}
else {
vErrors.push(err93);
}
errors++;
}
if(!pattern4.test(data27)){
const err94 = {instancePath:instancePath+"/media/canonicalURL",schemaPath:"#/$defs/MediaDescriptor/properties/canonicalURL/pattern",keyword:"pattern",params:{pattern: "^https?://"},message:"must match pattern \""+"^https?://"+"\""};
if(vErrors === null){
vErrors = [err94];
}
else {
vErrors.push(err94);
}
errors++;
}
if(!(formats2(data27))){
const err95 = {instancePath:instancePath+"/media/canonicalURL",schemaPath:"#/$defs/MediaDescriptor/properties/canonicalURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err95];
}
else {
vErrors.push(err95);
}
errors++;
}
}
else {
const err96 = {instancePath:instancePath+"/media/canonicalURL",schemaPath:"#/$defs/MediaDescriptor/properties/canonicalURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err96];
}
else {
vErrors.push(err96);
}
errors++;
}
}
if(data19.platform !== undefined){
let data28 = data19.platform;
if(typeof data28 !== "string"){
const err97 = {instancePath:instancePath+"/media/platform",schemaPath:"#/$defs/MediaDescriptor/properties/platform/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err97];
}
else {
vErrors.push(err97);
}
errors++;
}
if(!((((((((((((data28 === "generic") || (data28 === "x")) || (data28 === "youtube")) || (data28 === "wechat")) || (data28 === "xiaohongshu")) || (data28 === "douyin")) || (data28 === "bilibili")) || (data28 === "github")) || (data28 === "zhihu")) || (data28 === "medium")) || (data28 === "substack")) || (data28 === "toutiao"))){
const err98 = {instancePath:instancePath+"/media/platform",schemaPath:"#/$defs/MediaDescriptor/properties/platform/enum",keyword:"enum",params:{allowedValues: schema34.properties.platform.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err98];
}
else {
vErrors.push(err98);
}
errors++;
}
}
if(data19.ephemeralPlaybackURL !== undefined){
let data29 = data19.ephemeralPlaybackURL;
if(typeof data29 === "string"){
if(func1(data29) > 8192){
const err99 = {instancePath:instancePath+"/media/ephemeralPlaybackURL",schemaPath:"#/$defs/MediaDescriptor/properties/ephemeralPlaybackURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err99];
}
else {
vErrors.push(err99);
}
errors++;
}
if(!pattern5.test(data29)){
const err100 = {instancePath:instancePath+"/media/ephemeralPlaybackURL",schemaPath:"#/$defs/MediaDescriptor/properties/ephemeralPlaybackURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err100];
}
else {
vErrors.push(err100);
}
errors++;
}
if(!(formats2(data29))){
const err101 = {instancePath:instancePath+"/media/ephemeralPlaybackURL",schemaPath:"#/$defs/MediaDescriptor/properties/ephemeralPlaybackURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err101];
}
else {
vErrors.push(err101);
}
errors++;
}
}
else {
const err102 = {instancePath:instancePath+"/media/ephemeralPlaybackURL",schemaPath:"#/$defs/MediaDescriptor/properties/ephemeralPlaybackURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err102];
}
else {
vErrors.push(err102);
}
errors++;
}
}
if(data19.companionAudioURL !== undefined){
let data30 = data19.companionAudioURL;
if(typeof data30 === "string"){
if(func1(data30) > 8192){
const err103 = {instancePath:instancePath+"/media/companionAudioURL",schemaPath:"#/$defs/MediaDescriptor/properties/companionAudioURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err103];
}
else {
vErrors.push(err103);
}
errors++;
}
if(!pattern5.test(data30)){
const err104 = {instancePath:instancePath+"/media/companionAudioURL",schemaPath:"#/$defs/MediaDescriptor/properties/companionAudioURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err104];
}
else {
vErrors.push(err104);
}
errors++;
}
if(!(formats2(data30))){
const err105 = {instancePath:instancePath+"/media/companionAudioURL",schemaPath:"#/$defs/MediaDescriptor/properties/companionAudioURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err105];
}
else {
vErrors.push(err105);
}
errors++;
}
}
else {
const err106 = {instancePath:instancePath+"/media/companionAudioURL",schemaPath:"#/$defs/MediaDescriptor/properties/companionAudioURL/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err106];
}
else {
vErrors.push(err106);
}
errors++;
}
}
if(data19.mimeType !== undefined){
let data31 = data19.mimeType;
if((typeof data31 !== "string") && (data31 !== null)){
const err107 = {instancePath:instancePath+"/media/mimeType",schemaPath:"#/$defs/MediaDescriptor/properties/mimeType/type",keyword:"type",params:{type: schema34.properties.mimeType.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err107];
}
else {
vErrors.push(err107);
}
errors++;
}
if(typeof data31 === "string"){
if(func1(data31) > 256){
const err108 = {instancePath:instancePath+"/media/mimeType",schemaPath:"#/$defs/MediaDescriptor/properties/mimeType/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err108];
}
else {
vErrors.push(err108);
}
errors++;
}
}
}
if(data19.posterURL !== undefined){
let data32 = data19.posterURL;
if((typeof data32 !== "string") && (data32 !== null)){
const err109 = {instancePath:instancePath+"/media/posterURL",schemaPath:"#/$defs/MediaDescriptor/properties/posterURL/type",keyword:"type",params:{type: schema34.properties.posterURL.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err109];
}
else {
vErrors.push(err109);
}
errors++;
}
if(typeof data32 === "string"){
if(func1(data32) > 8192){
const err110 = {instancePath:instancePath+"/media/posterURL",schemaPath:"#/$defs/MediaDescriptor/properties/posterURL/maxLength",keyword:"maxLength",params:{limit: 8192},message:"must NOT have more than 8192 characters"};
if(vErrors === null){
vErrors = [err110];
}
else {
vErrors.push(err110);
}
errors++;
}
if(!pattern5.test(data32)){
const err111 = {instancePath:instancePath+"/media/posterURL",schemaPath:"#/$defs/MediaDescriptor/properties/posterURL/pattern",keyword:"pattern",params:{pattern: "^https://"},message:"must match pattern \""+"^https://"+"\""};
if(vErrors === null){
vErrors = [err111];
}
else {
vErrors.push(err111);
}
errors++;
}
if(!(formats2(data32))){
const err112 = {instancePath:instancePath+"/media/posterURL",schemaPath:"#/$defs/MediaDescriptor/properties/posterURL/format",keyword:"format",params:{format: "uri"},message:"must match format \""+"uri"+"\""};
if(vErrors === null){
vErrors = [err112];
}
else {
vErrors.push(err112);
}
errors++;
}
}
}
if(data19.durationSeconds !== undefined){
let data33 = data19.durationSeconds;
if((!(typeof data33 == "number")) && (data33 !== null)){
const err113 = {instancePath:instancePath+"/media/durationSeconds",schemaPath:"#/$defs/MediaDescriptor/properties/durationSeconds/type",keyword:"type",params:{type: schema34.properties.durationSeconds.type},message:"must be number,null"};
if(vErrors === null){
vErrors = [err113];
}
else {
vErrors.push(err113);
}
errors++;
}
if(typeof data33 == "number"){
if(data33 > 86400 || isNaN(data33)){
const err114 = {instancePath:instancePath+"/media/durationSeconds",schemaPath:"#/$defs/MediaDescriptor/properties/durationSeconds/maximum",keyword:"maximum",params:{comparison: "<=", limit: 86400},message:"must be <= 86400"};
if(vErrors === null){
vErrors = [err114];
}
else {
vErrors.push(err114);
}
errors++;
}
if(data33 < 0 || isNaN(data33)){
const err115 = {instancePath:instancePath+"/media/durationSeconds",schemaPath:"#/$defs/MediaDescriptor/properties/durationSeconds/minimum",keyword:"minimum",params:{comparison: ">=", limit: 0},message:"must be >= 0"};
if(vErrors === null){
vErrors = [err115];
}
else {
vErrors.push(err115);
}
errors++;
}
}
}
if(data19.author !== undefined){
let data34 = data19.author;
if((typeof data34 !== "string") && (data34 !== null)){
const err116 = {instancePath:instancePath+"/media/author",schemaPath:"#/$defs/MediaDescriptor/properties/author/type",keyword:"type",params:{type: schema34.properties.author.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err116];
}
else {
vErrors.push(err116);
}
errors++;
}
if(typeof data34 === "string"){
if(func1(data34) > 256){
const err117 = {instancePath:instancePath+"/media/author",schemaPath:"#/$defs/MediaDescriptor/properties/author/maxLength",keyword:"maxLength",params:{limit: 256},message:"must NOT have more than 256 characters"};
if(vErrors === null){
vErrors = [err117];
}
else {
vErrors.push(err117);
}
errors++;
}
}
}
if(data19.expiresAt !== undefined){
let data35 = data19.expiresAt;
if((typeof data35 !== "string") && (data35 !== null)){
const err118 = {instancePath:instancePath+"/media/expiresAt",schemaPath:"#/$defs/MediaDescriptor/properties/expiresAt/type",keyword:"type",params:{type: schema34.properties.expiresAt.type},message:"must be string,null"};
if(vErrors === null){
vErrors = [err118];
}
else {
vErrors.push(err118);
}
errors++;
}
if(typeof data35 === "string"){
if(!(formats0.validate(data35))){
const err119 = {instancePath:instancePath+"/media/expiresAt",schemaPath:"#/$defs/MediaDescriptor/properties/expiresAt/format",keyword:"format",params:{format: "date-time"},message:"must match format \""+"date-time"+"\""};
if(vErrors === null){
vErrors = [err119];
}
else {
vErrors.push(err119);
}
errors++;
}
}
}
if(data19.transcriptionCapability !== undefined){
let data36 = data19.transcriptionCapability;
if(typeof data36 !== "string"){
const err120 = {instancePath:instancePath+"/media/transcriptionCapability",schemaPath:"#/$defs/MediaDescriptor/properties/transcriptionCapability/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err120];
}
else {
vErrors.push(err120);
}
errors++;
}
if(!(((data36 === "supported") || (data36 === "conditional")) || (data36 === "unavailable"))){
const err121 = {instancePath:instancePath+"/media/transcriptionCapability",schemaPath:"#/$defs/MediaDescriptor/properties/transcriptionCapability/enum",keyword:"enum",params:{allowedValues: schema34.properties.transcriptionCapability.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err121];
}
else {
vErrors.push(err121);
}
errors++;
}
}
if(data19.failureReason !== undefined){
let data37 = data19.failureReason;
if(typeof data37 !== "string"){
const err122 = {instancePath:instancePath+"/media/failureReason",schemaPath:"#/$defs/MediaDescriptor/properties/failureReason/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err122];
}
else {
vErrors.push(err122);
}
errors++;
}
if(!((((((((data37 === "blob_or_mse") || (data37 === "multiple_candidates")) || (data37 === "video_not_loaded")) || (data37 === "no_transferable_source")) || (data37 === "drm_or_encrypted")) || (data37 === "browser_session_required")) || (data37 === "unsupported_media_type")) || (data37 === "unknown"))){
const err123 = {instancePath:instancePath+"/media/failureReason",schemaPath:"#/$defs/MediaDescriptor/properties/failureReason/enum",keyword:"enum",params:{allowedValues: schema34.properties.failureReason.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err123];
}
else {
vErrors.push(err123);
}
errors++;
}
}
if(data19.candidateCount !== undefined){
let data38 = data19.candidateCount;
if(!((typeof data38 == "number") && (!(data38 % 1) && !isNaN(data38)))){
const err124 = {instancePath:instancePath+"/media/candidateCount",schemaPath:"#/$defs/MediaDescriptor/properties/candidateCount/type",keyword:"type",params:{type: "integer"},message:"must be integer"};
if(vErrors === null){
vErrors = [err124];
}
else {
vErrors.push(err124);
}
errors++;
}
if(typeof data38 == "number"){
if(data38 > 1000 || isNaN(data38)){
const err125 = {instancePath:instancePath+"/media/candidateCount",schemaPath:"#/$defs/MediaDescriptor/properties/candidateCount/maximum",keyword:"maximum",params:{comparison: "<=", limit: 1000},message:"must be <= 1000"};
if(vErrors === null){
vErrors = [err125];
}
else {
vErrors.push(err125);
}
errors++;
}
if(data38 < 1 || isNaN(data38)){
const err126 = {instancePath:instancePath+"/media/candidateCount",schemaPath:"#/$defs/MediaDescriptor/properties/candidateCount/minimum",keyword:"minimum",params:{comparison: ">=", limit: 1},message:"must be >= 1"};
if(vErrors === null){
vErrors = [err126];
}
else {
vErrors.push(err126);
}
errors++;
}
}
}
if(data19.selectionReason !== undefined){
let data39 = data19.selectionReason;
if(typeof data39 !== "string"){
const err127 = {instancePath:instancePath+"/media/selectionReason",schemaPath:"#/$defs/MediaDescriptor/properties/selectionReason/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err127];
}
else {
vErrors.push(err127);
}
errors++;
}
if(!((((((data39 === "singleCandidate") || (data39 === "playing")) || (data39 === "recentInteraction")) || (data39 === "largestVisibleArea")) || (data39 === "nearestViewportCenter")) || (data39 === "ambiguous"))){
const err128 = {instancePath:instancePath+"/media/selectionReason",schemaPath:"#/$defs/MediaDescriptor/properties/selectionReason/enum",keyword:"enum",params:{allowedValues: schema34.properties.selectionReason.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err128];
}
else {
vErrors.push(err128);
}
errors++;
}
}
if(data19.playbackState !== undefined){
let data40 = data19.playbackState;
if(typeof data40 !== "string"){
const err129 = {instancePath:instancePath+"/media/playbackState",schemaPath:"#/$defs/MediaDescriptor/properties/playbackState/type",keyword:"type",params:{type: "string"},message:"must be string"};
if(vErrors === null){
vErrors = [err129];
}
else {
vErrors.push(err129);
}
errors++;
}
if(!(((((data40 === "playing") || (data40 === "paused")) || (data40 === "ended")) || (data40 === "notLoaded")) || (data40 === "unknown"))){
const err130 = {instancePath:instancePath+"/media/playbackState",schemaPath:"#/$defs/MediaDescriptor/properties/playbackState/enum",keyword:"enum",params:{allowedValues: schema34.properties.playbackState.enum},message:"must be equal to one of the allowed values"};
if(vErrors === null){
vErrors = [err130];
}
else {
vErrors.push(err130);
}
errors++;
}
}
}
else {
const err131 = {instancePath:instancePath+"/media",schemaPath:"#/$defs/MediaDescriptor/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err131];
}
else {
vErrors.push(err131);
}
errors++;
}
}
}
else {
const err132 = {instancePath,schemaPath:"#/type",keyword:"type",params:{type: "object"},message:"must be object"};
if(vErrors === null){
vErrors = [err132];
}
else {
vErrors.push(err132);
}
errors++;
}
validate23.errors = vErrors;
return errors === 0;
}
validate23.evaluated = {"props":true,"dynamicProps":false,"dynamicItems":false};


function validate20(data, {instancePath="", parentData, parentDataProperty, rootData=data, dynamicAnchors={}}={}){
/*# sourceURL="https://syc.local/linkdigest/capture-envelope-wire.schema.json" */;
let vErrors = null;
let errors = 0;
const evaluated0 = validate20.evaluated;
if(evaluated0.dynamicProps){
evaluated0.props = undefined;
}
if(evaluated0.dynamicItems){
evaluated0.items = undefined;
}
const _errs0 = errors;
let valid0 = false;
let passing0 = null;
const _errs1 = errors;
if(!(validate21(data, {instancePath,parentData,parentDataProperty,rootData,dynamicAnchors}))){
vErrors = vErrors === null ? validate21.errors : vErrors.concat(validate21.errors);
errors = vErrors.length;
}
var _valid0 = _errs1 === errors;
if(_valid0){
valid0 = true;
passing0 = 0;
var props0 = true;
}
const _errs2 = errors;
if(!(validate23(data, {instancePath,parentData,parentDataProperty,rootData,dynamicAnchors}))){
vErrors = vErrors === null ? validate23.errors : vErrors.concat(validate23.errors);
errors = vErrors.length;
}
var _valid0 = _errs2 === errors;
if(_valid0 && valid0){
valid0 = false;
passing0 = [passing0, 1];
}
else {
if(_valid0){
valid0 = true;
passing0 = 1;
if(props0 !== true){
props0 = true;
}
}
}
if(!valid0){
const err0 = {instancePath,schemaPath:"#/oneOf",keyword:"oneOf",params:{passingSchemas: passing0},message:"must match exactly one schema in oneOf"};
if(vErrors === null){
vErrors = [err0];
}
else {
vErrors.push(err0);
}
errors++;
}
else {
errors = _errs0;
if(vErrors !== null){
if(_errs0){
vErrors.length = _errs0;
}
else {
vErrors = null;
}
}
}
validate20.errors = vErrors;
evaluated0.props = props0;
return errors === 0;
}
validate20.evaluated = {"dynamicProps":true,"dynamicItems":false};

