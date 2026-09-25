/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { describe, it, expect } from '@ohos/hypium';
import { SubmitInfoUtil } from '../../../../main/ets/util/SubmitInfoUtil';
import { FeedbackData, FeedbackType, FeedbackInitParams } from '../../../../main/ets/model/FeedbackData';

export default function SubmitInfoUtilTest() {
  describe('SubmitInfoUtilTest', () => {
    it('filterReasonInfo_shouldFilterCorrectly', 0, () => {
      expect(SubmitInfoUtil.filterReasonInfo(['reason1', 'reason2', 'reason3'], [true, false, true])).assertEqual('reason1,reason3');
      expect(SubmitInfoUtil.filterReasonInfo(['a', 'b'], [true, true])).assertEqual('a,b');
      expect(SubmitInfoUtil.filterReasonInfo(['a', 'b'], [false, false])).assertEqual('');
      expect(SubmitInfoUtil.filterReasonInfo(['a', 'b'], [true])).assertEqual('');
      expect(SubmitInfoUtil.filterReasonInfo([], [])).assertEqual('');
    })

    it('getFeedbackReasonInfo_withLikeType_shouldReturnFromLikeList', 0, () => {
      const feedbackData = new FeedbackData();
      feedbackData.feedbackTypeStatus = FeedbackType.LIKE;
      feedbackData.likeReasonList = ['good1', 'good2'];
      expect(SubmitInfoUtil.getFeedbackReasonInfo(feedbackData, [true, false])).assertEqual('good1');
    })

    it('getFeedbackReasonInfo_withDislikeType_shouldReturnFromDislikeList', 0, () => {
      const feedbackData = new FeedbackData();
      feedbackData.feedbackTypeStatus = FeedbackType.DISLIKE;
      feedbackData.dislikeReasonList = ['bad1', 'bad2'];
      expect(SubmitInfoUtil.getFeedbackReasonInfo(feedbackData, [false, true])).assertEqual('bad2');
    })

    it('submitFeedbackInfo_shouldReturnPromise', 0, () => {
      const initParams = new FeedbackInitParams();
      initParams.domainTitle = 'Test Domain';
      const feedbackData = new FeedbackData();
      feedbackData.feedbackTypeStatus = FeedbackType.LIKE;
      feedbackData.likeReasonList = ['reason1'];
      const result = SubmitInfoUtil.submitFeedbackInfo(initParams, feedbackData, [true]);
      expect(result instanceof Promise).assertTrue();
    })

    it('submitFeedbackInfo_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const initParams = new FeedbackInitParams();
        initParams.domainTitle = 'Test';
        const feedbackData = new FeedbackData();
        feedbackData.feedbackTypeStatus = FeedbackType.DISLIKE;
        feedbackData.dislikeReasonList = ['bad1'];
        SubmitInfoUtil.submitFeedbackInfo(initParams, feedbackData, [true]);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('submitQuestionnaireInfo_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        SubmitInfoUtil.submitQuestionnaireInfo(5, 'great app');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('submitQuestionnaireInfo_withLowScore_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        SubmitInfoUtil.submitQuestionnaireInfo(1, 'needs improvement');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })
  })
}
