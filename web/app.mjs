import {moontile_plan, moontile_process} from './moontile.mjs';

const el = id => document.querySelector(`#${id}`);
const input = el('input'), canvas = el('canvas'), report = el('report'), mergeStatus = el('merge-status');
const planCanvas = el('plan-canvas'), planStatus = el('plan-status'), usePlan = el('use-plan');
const backgroundFile = el('background-file'), backgroundStatus = el('background-status'), clearBackground = el('clear-background');
const inputFile = el('input-file'), fileStatus = el('file-status'), saveResult = el('save-result');
const fields = ['image-width', 'image-height', 'tile-width', 'tile-height', 'overlap-x', 'overlap-y'];
let currentPlan = null;
let currentResult = null, background = null, backgroundUrl = null, backgroundVersion = 0;
let inputRevision = 0, importVersion = 0;

input.value = JSON.stringify({image_width:100,image_height:60,threshold:.5,metric:'ios',class_agnostic:false,strategy:'greedy_nmm',tiles:[{tile:{id:0,x:0,y:0,width:60,height:60},detections:[{id:1,image_id:1,tile_id:0,class_id:0,score:.95,box:{x1:45,y1:10,x2:60,y2:30}}]},{tile:{id:1,x:40,y:0,width:60,height:60},detections:[{id:2,image_id:1,tile_id:1,class_id:0,score:.85,box:{x1:10,y1:10,x2:30,y2:30}}]}]}, null, 2);

function rect(svg, x, y, width, height, cls) {
  const node = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  for (const [key, value] of Object.entries({x,y,width,height,class:cls})) node.setAttribute(key, value);
  svg.append(node);
}
function setView(svg, width, height) {
  svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
  svg.replaceChildren();
  if (!background || background.width !== width || background.height !== height) return false;
  const image = document.createElementNS('http://www.w3.org/2000/svg', 'image');
  for (const [key, value] of Object.entries({x:0,y:0,width,height,href:background.url,preserveAspectRatio:'none'})) image.setAttribute(key, value);
  svg.append(image);
  return true;
}
function renderPlan(event) {
  event?.preventDefault();
  currentPlan = null;
  usePlan.disabled = true;
  planCanvas.replaceChildren();
  try {
    const values = fields.map(id => Number(el(id).value));
    if (fields.some(id => el(id).value.trim() === '') || values.some(value => !Number.isSafeInteger(value))) throw Error('请输入整数尺寸与重叠量');
    const [image_width,image_height,tile_width,tile_height,overlap_x,overlap_y] = values;
    const plan = JSON.parse(moontile_plan(JSON.stringify({image_width,image_height,tile_width,tile_height,overlap_x,overlap_y})));
    if (plan.error) throw Error(plan.error);
    currentPlan = plan;
    drawPlan(plan);
    usePlan.disabled = false;
  } catch (error) {
    planStatus.textContent = `规划失败：${error.message}`;
  }
}
function drawPlan(plan) {
  const backgroundMatches = setView(planCanvas, plan.image_width, plan.image_height);
  for (const tile of plan.tiles.slice(0, 1000)) {
    rect(planCanvas, tile.x, tile.y, tile.width, tile.height, 'tile');
    if (plan.tiles.length <= 100) {
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      const size = Math.min(tile.width, tile.height) * .08;
      label.setAttribute('x', tile.x + size * .3); label.setAttribute('y', tile.y + size * 1.2);
      label.setAttribute('font-size', size); label.setAttribute('class', 'tile-label');
      label.textContent = String(tile.id); planCanvas.append(label);
    }
  }
  planStatus.textContent = `已生成 ${plan.tiles.length} 个切片` + (plan.tiles.length > 1000 ? '；图中显示前 1000 个。' : '。') +
    (background && !backgroundMatches ? ' 背景图尺寸与规划不一致，未显示。' : '');
}
function drawMerge(src, out) {
  const backgroundMatches = setView(canvas, src.image_width, src.image_height);
  for (const {tile:t} of src.tiles.slice(0, 1000)) rect(canvas, t.x, t.y, t.width, t.height, 'tile');
  const messages = [];
  if (src.tiles.length > 1000) messages.push('图中显示前 1000 个切片；结果包含全部输入。');
  if (background && !backgroundMatches) messages.push('背景图尺寸与预测输入不一致，未显示。');
  mergeStatus.textContent = messages.join(' ');
  const suppressed = new Set(out.suppressed.map(item => item.suppressed_id));
  for (const d of out.restored) { const b=d.box; rect(canvas,b.x1,b.y1,b.x2-b.x1,b.y2-b.y1,suppressed.has(d.id)?'suppressed':'source'); }
  for (const d of out.kept) { const b=d.box; rect(canvas,b.x1,b.y1,b.x2-b.x1,b.y2-b.y1,'kept'); }
}
function computeMerge(source) {
  const src = JSON.parse(source), out = JSON.parse(moontile_process(source));
  if (out.error) throw Error(out.error);
  return {src, out};
}
function showResult(result) {
  currentResult = result;
  drawMerge(result.src, result.out);
  report.textContent = JSON.stringify(result.out, null, 2);
  saveResult.disabled = false;
}
function renderMerge() {
  canvas.replaceChildren(); mergeStatus.textContent = ''; currentResult = null; saveResult.disabled = true;
  try { showResult(computeMerge(input.value)); }
  catch (error) { report.textContent = `处理失败：${error.message}`; }
}
function refreshBackground() {
  if (currentPlan) drawPlan(currentPlan);
  if (currentResult) drawMerge(currentResult.src, currentResult.out);
}
function clearImage() {
  backgroundVersion++;
  background = null;
  if (backgroundUrl) URL.revokeObjectURL(backgroundUrl);
  backgroundUrl = null;
  clearBackground.disabled = true;
  backgroundFile.value = '';
  backgroundStatus.textContent = '未选择背景图。';
  refreshBackground();
}
backgroundFile.addEventListener('change', () => {
  const file = backgroundFile.files?.[0];
  clearImage();
  if (!file) return;
  if (!['image/png','image/jpeg','image/webp'].includes(file.type)) {
    backgroundStatus.textContent = '请选择 PNG、JPEG 或 WebP 图片。';
    return;
  }
  const version = backgroundVersion;
  try {
    const url = URL.createObjectURL(file);
    backgroundUrl = url;
    const image = new Image();
    backgroundStatus.textContent = '正在读取图片…';
    image.onload = () => {
      if (version !== backgroundVersion) return;
      if (image.naturalWidth <= 0 || image.naturalHeight <= 0) { image.onerror(); return; }
      background = {url, width:image.naturalWidth, height:image.naturalHeight};
      clearBackground.disabled = false;
      backgroundStatus.textContent = `已载入 ${file.name}（${background.width} × ${background.height}）。`;
      refreshBackground();
    };
    image.onerror = () => {
      if (version !== backgroundVersion) return;
      clearImage();
      backgroundStatus.textContent = '图片读取失败，请选择有效的图片文件。';
    };
    image.src = url;
  } catch (_error) {
    clearImage();
    backgroundStatus.textContent = '图片读取失败，请选择有效的图片文件。';
  }
});
clearBackground.addEventListener('click', clearImage);
window.addEventListener('pagehide', () => { clearImage(); importVersion++; });
el('plan-form').addEventListener('submit', renderPlan);
for (const id of fields) el(id).addEventListener('input', () => {
  currentPlan = null; usePlan.disabled = true; planCanvas.replaceChildren();
  planStatus.textContent = '参数已修改，请重新生成规划。';
});
usePlan.addEventListener('click', () => {
  if (!currentPlan) return;
  inputRevision++;
  input.value = JSON.stringify({image_width:currentPlan.image_width,image_height:currentPlan.image_height,threshold:.5,metric:'iou',class_agnostic:false,tiles:currentPlan.tiles.map(tile => ({tile,detections:[]}))}, null, 2);
  fileStatus.textContent = '已使用规划替换输入。';
  renderMerge();
});
el('run').addEventListener('click', renderMerge);
input.addEventListener('input', () => {
  inputRevision++;
  currentResult = null; canvas.replaceChildren(); mergeStatus.textContent = '';
  saveResult.disabled = true;
  report.textContent = '输入已修改，请重新运行合并。';
});
inputFile.addEventListener('change', async () => {
  const file = inputFile.files?.[0];
  inputFile.value = '';
  const version = ++importVersion;
  if (!file) return;
  const revision = inputRevision;
  fileStatus.textContent = '正在读取预测文件…';
  try {
    const source = await file.text();
    if (version !== importVersion) return;
    if (revision !== inputRevision) { fileStatus.textContent = '读取期间输入已变化，未替换当前内容。'; return; }
    const result = computeMerge(source);
    inputRevision++;
    input.value = source;
    showResult(result);
    fileStatus.textContent = `已导入并处理 ${file.name}。`;
  } catch (error) {
    if (version !== importVersion) return;
    if (revision !== inputRevision) { fileStatus.textContent = '读取期间输入已变化，未替换当前内容。'; return; }
    fileStatus.textContent = `导入失败，当前输入未改变：${error.message}`;
  }
});
function downloadJson(name, source) {
  const url = URL.createObjectURL(new Blob([source], {type:'application/json;charset=utf-8'}));
  try {
    const link = document.createElement('a');
    link.href = url; link.download = name; link.click();
  } finally { setTimeout(() => URL.revokeObjectURL(url), 0); }
}
el('save-input').addEventListener('click', () => {
  try {
    JSON.parse(input.value);
    downloadJson('moontile-input.json', input.value);
    fileStatus.textContent = '已准备输入 JSON 下载。';
  } catch (error) { fileStatus.textContent = `无法下载输入：${error.message}`; }
});
saveResult.addEventListener('click', () => {
  if (!currentResult) return;
  try {
    downloadJson('moontile-result.json', JSON.stringify(currentResult.out, null, 2));
    fileStatus.textContent = '已准备结果 JSON 下载。';
  } catch (error) { fileStatus.textContent = `无法下载结果：${error.message}`; }
});
renderPlan();
renderMerge();
